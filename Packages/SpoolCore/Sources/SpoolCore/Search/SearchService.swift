import Foundation
import GRDB

/// A fixed whitelist mapping each sort option to a trusted SQL fragment — `ORDER BY`
/// can't be parameterized the way `WHERE` values can, so the lookup itself (not string
/// escaping) is what keeps this injection-safe, mirroring the source app's
/// `SORT_CLAUSES` pattern.
public enum LibrarySortOrder: String, Sendable, CaseIterable {
    case newest
    case oldest
    case nameAsc = "name_asc"
    case nameDesc = "name_desc"
    case sizeDesc = "size_desc"
    case sizeAsc = "size_asc"

    var sqlFragment: String {
        switch self {
        case .newest: return "files.first_seen_at DESC"
        case .oldest: return "files.first_seen_at ASC"
        case .nameAsc: return "COALESCE(files.display_name, files.filename) COLLATE NOCASE ASC"
        case .nameDesc: return "COALESCE(files.display_name, files.filename) COLLATE NOCASE DESC"
        case .sizeDesc: return "files.size_bytes DESC"
        case .sizeAsc: return "files.size_bytes ASC"
        }
    }
}

/// Structured filters for the library grid — extension/tag/rating/printed/material/
/// printer/slicer — layered on top of the free-text `query`/`sort` search, mirroring
/// the source app's `search_files` filter parameters exactly. All empty/`.any` by
/// default (no filtering).
public struct LibraryFilters: Sendable, Equatable {
    public enum PrintedFilter: Sendable, Equatable {
        case any, yes, no
    }

    public var extensions: Set<String> = []
    public var tags: Set<String> = []
    public var ratings: Set<Int> = []
    public var printed: PrintedFilter = .any
    public var material: String?
    public var printerProfile: String?
    public var slicer: String?

    public init() {}

    public var isEmpty: Bool {
        extensions.isEmpty && tags.isEmpty && ratings.isEmpty && printed == .any
            && material == nil && printerProfile == nil && slicer == nil
    }
}

/// Library search: normalized name matching (hyphen/underscore/space-equivalent, via
/// the trigger-maintained `*_normalized` columns), print-metadata/print-log text
/// matching, and a structured-metadata phrase heuristic ("0.2mm nozzle", "20% infill").
/// When `query` is set, results are relevance-tiered (exact > name-prefix >
/// name-substring > metadata-only match) with the user's chosen sort as the tiebreak
/// *within* each tier — deliberately plain `LIKE` tiering rather than SQLite FTS5,
/// since FTS5 tokenizes into words, which fights this app's actual search patterns
/// (partial/substring hits inside hyphenated or version-suffixed filenames like
/// `top-plug-6mm.stl` or `_v2`). No query = plain sort, completely unaffected.
public struct SearchService: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func search(
        query: String? = nil, sort: LibrarySortOrder = .newest, filters: LibraryFilters = LibraryFilters(),
        limit: Int = 60, offset: Int = 0
    ) async throws -> [SpoolFile] {
        let (sql, arguments) = Self.buildQuery(query: query, sort: sort, filters: filters, limit: limit, offset: offset)
        return try await writer.read { conn in
            try SpoolFile.fetchAll(conn, sql: sql, arguments: arguments)
        }
    }

    public func distinctMaterials() async throws -> [String] {
        try await writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT DISTINCT material FROM print_metadata WHERE material IS NOT NULL ORDER BY material")
        }
    }

    public func distinctPrinterProfiles() async throws -> [String] {
        try await writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT DISTINCT printer_profile FROM print_metadata WHERE printer_profile IS NOT NULL ORDER BY printer_profile")
        }
    }

    public func distinctSlicers() async throws -> [String] {
        try await writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT DISTINCT slicer FROM print_metadata WHERE slicer IS NOT NULL ORDER BY slicer")
        }
    }

    /// Pure SQL-building half of `search`, split out so it can also drive a live
    /// `ValueObservation.tracking { db in ... }` closure (which is synchronous and
    /// can't call the `async` method above) — the browse UI stays live-updating while
    /// searching, not just while browsing unfiltered.
    public static func buildQuery(
        query: String?, sort: LibrarySortOrder, filters: LibraryFilters = LibraryFilters(), limit: Int = 60, offset: Int = 0
    ) -> (sql: String, arguments: StatementArguments) {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasQuery = !trimmed.isEmpty
        let normalized = SpoolTextNormalization.normalize(trimmed)
        let structuredMatch = hasQuery ? StructuredSearchParser.parse(trimmed) : nil

        var arguments: [String: (any DatabaseValueConvertible)?] = [
            "hasQuery": hasQuery,
            "normalizedQuery": normalized,
            "rawQuery": trimmed,
            "limit": limit,
            "offset": offset,
        ]

        // SQLite's dynamic typing makes this safe without an explicit numeric-looking
        // guard (unlike Postgres's `::float` cast, which can raise at runtime on a
        // non-numeric value): a missing key makes `json_extract` NULL, and arithmetic
        // against NULL is NULL — both fail the comparison rather than erroring.
        var structuredClause = "0"
        if let structuredMatch {
            structuredClause = """
                ABS(json_extract(print_metadata.settings_json, '$.\(structuredMatch.field)') - :structuredValue) <= :structuredTolerance
                """
            arguments["structuredValue"] = structuredMatch.value
            arguments["structuredTolerance"] = structuredMatch.tolerance
        }

        var extraConditions: [String] = []
        if !filters.extensions.isEmpty {
            let names = Array(filters.extensions)
            let placeholders = names.indices.map { _ in "?" }.joined(separator: ",")
            extraConditions.append("files.ext IN (\(placeholders))")
        }
        if !filters.tags.isEmpty {
            let names = Array(filters.tags)
            let placeholders = names.indices.map { _ in "?" }.joined(separator: ",")
            extraConditions.append("""
                files.id IN (SELECT ft.file_id FROM file_tags ft JOIN tags t ON t.id = ft.tag_id WHERE t.name IN (\(placeholders)))
                """)
        }
        if !filters.ratings.isEmpty {
            let ratings = Array(filters.ratings)
            let placeholders = ratings.indices.map { _ in "?" }.joined(separator: ",")
            extraConditions.append("files.id IN (SELECT file_id FROM print_log WHERE rating IN (\(placeholders)))")
        }
        switch filters.printed {
        case .any: break
        case .yes: extraConditions.append("files.id IN (SELECT file_id FROM print_log WHERE printed = 1)")
        case .no: extraConditions.append("files.id NOT IN (SELECT file_id FROM print_log WHERE printed = 1)")
        }
        if filters.material != nil { extraConditions.append("print_metadata.material = ?") }
        if filters.printerProfile != nil { extraConditions.append("print_metadata.printer_profile = ?") }
        if filters.slicer != nil { extraConditions.append("print_metadata.slicer = ?") }
        let extraWhere = extraConditions.isEmpty ? "" : "AND " + extraConditions.joined(separator: " AND ")

        // Named (`:xxx`) and positional (`?`) placeholders can't mix in one GRDB
        // statement — the free-text/relevance-tiering half above is named throughout,
        // so every filter's own placeholders are appended as *trailing positional*
        // arguments instead, in the exact order their `?`s appear in `extraWhere`.
        var positionalFilterValues: [any DatabaseValueConvertible] = []
        positionalFilterValues.append(contentsOf: Array(filters.extensions))
        positionalFilterValues.append(contentsOf: Array(filters.tags))
        positionalFilterValues.append(contentsOf: Array(filters.ratings))
        if let material = filters.material { positionalFilterValues.append(material) }
        if let printerProfile = filters.printerProfile { positionalFilterValues.append(printerProfile) }
        if let slicer = filters.slicer { positionalFilterValues.append(slicer) }

        let sql = """
            SELECT files.* FROM files
            LEFT JOIN print_metadata ON print_metadata.file_id = files.id
            LEFT JOIN print_log ON print_log.file_id = files.id
            WHERE files.status = 'active'
              AND (
                :hasQuery = 0
                OR files.filename_normalized LIKE '%' || :normalizedQuery || '%'
                OR files.display_name_normalized LIKE '%' || :normalizedQuery || '%'
                OR print_metadata.material LIKE '%' || :rawQuery || '%'
                OR print_metadata.printer_profile LIKE '%' || :rawQuery || '%'
                OR print_metadata.slicer LIKE '%' || :rawQuery || '%'
                OR print_metadata.notes LIKE '%' || :rawQuery || '%'
                OR print_log.comments LIKE '%' || :rawQuery || '%'
                OR \(structuredClause)
              )
              \(extraWhere)
            ORDER BY
              CASE
                WHEN :hasQuery = 0 THEN 0
                WHEN files.filename_normalized = :normalizedQuery
                     OR files.display_name_normalized = :normalizedQuery THEN 0
                WHEN files.filename_normalized LIKE :normalizedQuery || '%'
                     OR files.display_name_normalized LIKE :normalizedQuery || '%' THEN 1
                WHEN files.filename_normalized LIKE '%' || :normalizedQuery || '%'
                     OR files.display_name_normalized LIKE '%' || :normalizedQuery || '%' THEN 2
                ELSE 3
              END,
              \(sort.sqlFragment)
            LIMIT :limit OFFSET :offset
            """

        return (sql, StatementArguments(arguments) + StatementArguments(positionalFilterValues))
    }

    // MARK: - Collapsing fully-matching projects into one card

    private static let maxProjectCardThumbnails = 4

    /// Walks the already-sorted matching set and replaces every file belonging to a
    /// "fully matching" project (2+ confirmed active member files, *all* of which are
    /// in this matching set) with a single project card at that project's first
    /// occurrence — so a search that happens to match an entire project's files reads
    /// as "here's a project," not a wall of individually-identical-looking file cards.
    /// A file belonging to more than one fully-matching project at once has the
    /// alphabetically-first one win (memberships are fetched name-ordered); the file is
    /// simply dropped from the losing project's card, which still collapses correctly
    /// from its other members. Synchronous over a `Database` (not `async`) so it can
    /// run directly inside a `ValueObservation.tracking` closure — the browse grid
    /// keeps updating live even while a collapsed project card is showing.
    public static func collapseFullyMatchingProjects(rows: [SpoolFile], in db: Database) throws -> [LibrarySearchItem] {
        let fileIds = rows.compactMap(\.id)
        guard !fileIds.isEmpty else { return rows.map { .file($0) } }

        let placeholders = fileIds.indices.map { _ in "?" }.joined(separator: ",")
        let membershipRows = try Row.fetchAll(db, sql: """
            SELECT pf.file_id AS file_id, p.id AS project_id, p.name AS project_name, p.color AS project_color
            FROM project_files pf JOIN projects p ON p.id = pf.project_id
            WHERE pf.status = 'confirmed' AND pf.file_id IN (\(placeholders))
            ORDER BY p.name
            """, arguments: StatementArguments(fileIds))

        var membershipsByFileId: [Int64: [(id: Int64, name: String, color: ProjectColor)]] = [:]
        var candidateProjectIds: Set<Int64> = []
        for row in membershipRows {
            let fileId: Int64 = row["file_id"]
            let projectId: Int64 = row["project_id"]
            let name: String = row["project_name"]
            let color = ProjectColor(rawValue: row["project_color"]) ?? .blue
            membershipsByFileId[fileId, default: []].append((projectId, name, color))
            candidateProjectIds.insert(projectId)
        }
        guard !candidateProjectIds.isEmpty else { return rows.map { .file($0) } }

        let matchingFileIdSet = Set(fileIds)
        var fullyMatchingCount: [Int64: Int] = [:]
        for projectId in candidateProjectIds {
            let memberIds = try Int64.fetchSet(db, sql: """
                SELECT files.id FROM files
                JOIN project_files ON project_files.file_id = files.id
                WHERE project_files.project_id = ? AND project_files.status = 'confirmed' AND files.status = 'active'
                """, arguments: [projectId])
            let matchingCount = memberIds.intersection(matchingFileIdSet).count
            if matchingCount > 1 && matchingCount == memberIds.count {
                fullyMatchingCount[projectId] = matchingCount
            }
        }
        guard !fullyMatchingCount.isEmpty else { return rows.map { .file($0) } }

        var thumbnailsByProject: [Int64: [String]] = [:]
        var extensionsByProject: [Int64: Set<String>] = [:]
        for row in rows {
            guard let fileId = row.id, let memberships = membershipsByFileId[fileId] else { continue }
            for membership in memberships where fullyMatchingCount[membership.id] != nil {
                if let thumbnailPath = row.thumbnailPath {
                    var bucket = thumbnailsByProject[membership.id, default: []]
                    if bucket.count < maxProjectCardThumbnails {
                        bucket.append(thumbnailPath)
                        thumbnailsByProject[membership.id] = bucket
                    }
                }
                extensionsByProject[membership.id, default: []].insert(mergedExtensionLabel(row.ext))
            }
        }

        var items: [LibrarySearchItem] = []
        var alreadyCarded: Set<Int64> = []
        for row in rows {
            guard let fileId = row.id else { items.append(.file(row)); continue }
            let ownCollapsible = (membershipsByFileId[fileId] ?? []).filter { fullyMatchingCount[$0.id] != nil }
            if let target = ownCollapsible.first(where: { !alreadyCarded.contains($0.id) }) {
                items.append(.project(ProjectSearchCard(
                    projectId: target.id, name: target.name, color: target.color, fileCount: fullyMatchingCount[target.id] ?? 0,
                    thumbnailPaths: thumbnailsByProject[target.id] ?? [],
                    extensions: (extensionsByProject[target.id] ?? []).sorted()
                )))
                alreadyCarded.insert(target.id)
                continue
            }
            if ownCollapsible.contains(where: { alreadyCarded.contains($0.id) }) { continue }
            items.append(.file(row))
        }
        return items
    }

    private static func mergedExtensionLabel(_ ext: String) -> String {
        let lower = ext.lowercased()
        return (lower == "step" || lower == "stp") ? "STEP" : lower.uppercased()
    }
}

/// One row of a (possibly-collapsed) library search result — either a real file or a
/// project card standing in for every one of its (all matching) confirmed files.
public enum LibrarySearchItem: Sendable, Identifiable {
    case file(SpoolFile)
    case project(ProjectSearchCard)

    public var id: String {
        switch self {
        case .file(let file): return "f\(file.id ?? -1)"
        case .project(let card): return "p\(card.projectId)"
        }
    }
}

public struct ProjectSearchCard: Sendable {
    public let projectId: Int64
    public let name: String
    public let color: ProjectColor
    public let fileCount: Int
    public let thumbnailPaths: [String]
    public let extensions: [String]
}

struct StructuredQueryMatch {
    let field: String
    let value: Double
    let tolerance: Double
}

/// Not a real parser — a keyword-presence + nearest-number heuristic, same as the
/// source app: "nozzle"/"layer"/"infill" appearing anywhere in the query, plus the
/// first number found anywhere in the query, so both "0.2mm nozzle" and "nozzle 0.2mm"
/// work. `field` values must match `PrintSettings`' actual JSON key names exactly.
enum StructuredSearchParser {
    static func parse(_ query: String) -> StructuredQueryMatch? {
        let lowered = query.lowercased()
        guard let number = firstNumber(in: lowered) else { return nil }

        if lowered.contains("nozzle") {
            return StructuredQueryMatch(field: "nozzleDiameterMM", value: number, tolerance: 0.005)
        } else if lowered.contains("layer") {
            return StructuredQueryMatch(field: "layerHeightMM", value: number, tolerance: 0.005)
        } else if lowered.contains("infill") {
            return StructuredQueryMatch(field: "infillPercent", value: number, tolerance: 0.5)
        }
        return nil
    }

    private static func firstNumber(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(\.\d+)?)"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let numberRange = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[numberRange])
    }
}
