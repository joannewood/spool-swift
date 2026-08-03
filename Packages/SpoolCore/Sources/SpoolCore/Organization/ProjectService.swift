import Foundation
import GRDB

/// Nestable projects: create/rename/reparent, and manual membership changes (always
/// `status = 'confirmed'` — a deliberate user action, unlike the suggestion-heuristic
/// inserts elsewhere which start at `'suggested'`).
public struct ProjectService: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func createProject(name: String, parentProjectId: Int64? = nil) async throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(name: trimmed.isEmpty ? name : trimmed, parentProjectId: parentProjectId)
        return try await writer.write { conn in try project.inserted(conn) }
    }

    public func rename(projectId: Int64, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try await writer.write { conn in
            try conn.execute(sql: "UPDATE projects SET name = ? WHERE id = ?", arguments: [trimmed, projectId])
        }
    }

    /// `newParentId == projectId` (a project can't be its own parent) is silently
    /// ignored rather than corrupting the tree into a cycle.
    public func reparent(projectId: Int64, toParentId newParentId: Int64?) async throws {
        guard newParentId != projectId else { return }
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE projects SET parent_project_id = ? WHERE id = ?", arguments: [newParentId, projectId]
            )
        }
    }

    public func addFile(fileId: Int64, toProjectId projectId: Int64) async throws {
        try await writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'confirmed')
                ON CONFLICT (project_id, file_id) DO UPDATE SET status = 'confirmed'
                """, arguments: [projectId, fileId])
        }
    }

    /// Bulk add — the library grid's multi-select "Add to Project" action, one write
    /// transaction for the whole batch rather than one round trip per file.
    public func addFiles(fileIds: [Int64], toProjectId projectId: Int64) async throws {
        guard !fileIds.isEmpty else { return }
        try await writer.write { conn in
            for fileId in fileIds {
                try conn.execute(sql: """
                    INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'confirmed')
                    ON CONFLICT (project_id, file_id) DO UPDATE SET status = 'confirmed'
                    """, arguments: [projectId, fileId])
            }
        }
    }

    public func removeFile(fileId: Int64, fromProjectId projectId: Int64) async throws {
        try await writer.write { conn in
            try conn.execute(
                sql: "DELETE FROM project_files WHERE project_id = ? AND file_id = ?",
                arguments: [projectId, fileId]
            )
            try ProjectCleanup.deleteIfEmptyAndAutoCreated(projectId: projectId, conn: conn)
        }
    }

    /// A project given any color other than the default blue sorts first — a flag for
    /// "pay attention to this one" — with alphabetical order as the tiebreak both within
    /// the colored group and within the uncolored (blue) group.
    private static let colorFirstThenNameOrdering = "(CASE WHEN color = 'blue' THEN 1 ELSE 0 END), name"

    public func allProjects() async throws -> [Project] {
        try await writer.read { conn in
            try Project.fetchAll(conn, sql: "SELECT * FROM projects ORDER BY \(Self.colorFirstThenNameOrdering)")
        }
    }

    public func childProjects(ofParentId parentId: Int64?) async throws -> [Project] {
        try await writer.read { conn in
            if let parentId {
                return try Project.fetchAll(conn, sql: """
                    SELECT * FROM projects WHERE parent_project_id = ? ORDER BY \(Self.colorFirstThenNameOrdering)
                    """, arguments: [parentId])
            } else {
                return try Project.fetchAll(conn, sql: """
                    SELECT * FROM projects WHERE parent_project_id IS NULL ORDER BY \(Self.colorFirstThenNameOrdering)
                    """)
            }
        }
    }

    /// Sets a project's flag color — a native-app addition, no source-app equivalent.
    public func setColor(projectId: Int64, to color: ProjectColor) async throws {
        try await writer.write { conn in
            try conn.execute(sql: "UPDATE projects SET color = ? WHERE id = ?", arguments: [color.rawValue, projectId])
        }
    }

    /// Confirmed membership only — a suggested-but-not-yet-reviewed membership doesn't
    /// belong on the project's own "these are my files" page.
    public func confirmedFiles(inProjectId projectId: Int64) async throws -> [SpoolFile] {
        try await writer.read { conn in
            try SpoolFile.fetchAll(conn, sql: """
                SELECT files.* FROM files
                JOIN project_files ON project_files.file_id = files.id
                WHERE project_files.project_id = ? AND project_files.status = 'confirmed'
                  AND files.status = 'active'
                ORDER BY files.first_seen_at DESC
                """, arguments: [projectId])
        }
    }

    /// Files the folder-grouping suggestion heuristic proposed for this project but
    /// nobody has confirmed or rejected yet — shown in their own section on the
    /// project's own page so a suggestion doesn't require navigating to the file's own
    /// detail page to review.
    public func suggestedFiles(inProjectId projectId: Int64) async throws -> [SpoolFile] {
        try await writer.read { conn in
            try SpoolFile.fetchAll(conn, sql: """
                SELECT files.* FROM files
                JOIN project_files ON project_files.file_id = files.id
                WHERE project_files.project_id = ? AND project_files.status = 'suggested'
                  AND files.status = 'active'
                ORDER BY files.first_seen_at DESC
                """, arguments: [projectId])
        }
    }

    public func projectMemberships(forFileId fileId: Int64) async throws -> [ProjectFile] {
        try await writer.read { conn in
            try ProjectFile.filter(Column("file_id") == fileId).fetchAll(conn)
        }
    }

    // MARK: - Summaries, card visuals

    private static let maxProjectCardThumbnails = 4

    /// A project's members plus every descendant's, at any depth — a pure "umbrella"
    /// project (all its real files living in sub-projects, none directly in it) would
    /// otherwise misleadingly report zero files/no thumbnails.
    private static let closureCTE = """
        WITH RECURSIVE closure(ancestor_id, descendant_id) AS (
            SELECT id, id FROM projects
            UNION ALL
            SELECT closure.ancestor_id, projects.id
            FROM closure JOIN projects ON projects.parent_project_id = closure.descendant_id
        )
        """

    /// Every project with a *recursive* member-file count and sub-project count — the
    /// base data for the Projects cards view (and its search), which needs both counts
    /// even for an umbrella project with no directly-assigned files.
    public func projectSummaries() async throws -> [ProjectSummary] {
        try await writer.read { conn in
            let rows = try Row.fetchAll(conn, sql: Self.closureCTE + """
                SELECT p.id AS id, p.name AS name, p.description AS description,
                       p.parent_project_id AS parent_project_id, p.created_at AS created_at,
                       p.source_folder_path AS source_folder_path, p.color AS color,
                       COUNT(DISTINCT CASE WHEN pf.status = 'confirmed' THEN pf.file_id END) AS file_count,
                       COUNT(DISTINCT CASE WHEN cl.descendant_id != p.id THEN cl.descendant_id END) AS subproject_count
                FROM projects p
                JOIN closure cl ON cl.ancestor_id = p.id
                LEFT JOIN project_files pf ON pf.project_id = cl.descendant_id
                GROUP BY p.id
                ORDER BY \(Self.colorFirstThenNameOrdering)
                """)
            return try rows.map { row in
                ProjectSummary(
                    project: try Project(row: row),
                    fileCount: row["file_count"],
                    subprojectCount: row["subproject_count"]
                )
            }
        }
    }

    /// Up to `maxProjectCardThumbnails` real file thumbnails and the sorted distinct
    /// file extensions (.step/.stp merged into one "STEP" badge) for each given
    /// project, pulled from its own files and every descendant's — one batched query
    /// keyed off every project id, not one query per card.
    public func projectCardVisuals(forProjectIds projectIds: [Int64]) async throws -> [Int64: ProjectCardVisuals] {
        guard !projectIds.isEmpty else { return [:] }
        return try await writer.read { conn in
            let placeholders = projectIds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(conn, sql: Self.closureCTE + """
                SELECT cl.ancestor_id AS project_id, f.thumbnail_path AS thumbnail_path, f.ext AS ext
                FROM closure cl
                JOIN project_files pf ON pf.project_id = cl.descendant_id AND pf.status = 'confirmed'
                JOIN files f ON f.id = pf.file_id AND f.status = 'active'
                WHERE cl.ancestor_id IN (\(placeholders))
                ORDER BY f.first_seen_at DESC
                """, arguments: StatementArguments(projectIds))

            var thumbnailsByProject: [Int64: [String]] = [:]
            var extensionsByProject: [Int64: Set<String>] = [:]
            for row in rows {
                let projectId: Int64 = row["project_id"]
                if let thumbnailPath: String = row["thumbnail_path"] {
                    var bucket = thumbnailsByProject[projectId, default: []]
                    if bucket.count < Self.maxProjectCardThumbnails {
                        bucket.append(thumbnailPath)
                        thumbnailsByProject[projectId] = bucket
                    }
                }
                let ext: String = row["ext"]
                extensionsByProject[projectId, default: []].insert(Self.mergedExtensionLabel(ext))
            }
            return Dictionary(uniqueKeysWithValues: projectIds.map { projectId in
                (projectId, ProjectCardVisuals(
                    thumbnailPaths: thumbnailsByProject[projectId] ?? [],
                    extensions: (extensionsByProject[projectId] ?? []).sorted()
                ))
            })
        }
    }

    private static func mergedExtensionLabel(_ ext: String) -> String {
        let lower = ext.lowercased()
        return (lower == "step" || lower == "stp") ? "STEP" : lower.uppercased()
    }

    // MARK: - Name cleanup

    /// Every project whose name `ProjectNaming.suggestCleanName` would actually change,
    /// for the bulk-rename review — most project names come straight from a downloaded
    /// kit's own folder name. Only surfaces a suggestion that's a stable fixed point
    /// (re-running the heuristic on its own output produces the same string again) — a
    /// suggestion this can't guarantee is actually final shouldn't be offered as if it
    /// were (a real non-idempotent-heuristic bug was caught exactly this way upstream).
    public func projectsNeedingNameCleanup() async throws -> [ProjectRenameSuggestion] {
        let projects = try await allProjects()
        return projects.compactMap { project -> ProjectRenameSuggestion? in
            let suggested = ProjectNaming.suggestCleanName(project.name)
            guard suggested != project.name, ProjectNaming.suggestCleanName(suggested) == suggested else { return nil }
            return ProjectRenameSuggestion(project: project, suggestedName: suggested)
        }
    }

    /// Applies a batch of (project id, new name) pairs from the cleanup review UI —
    /// each name may be the heuristic's own suggestion or something the user hand-edited
    /// first, and rows can be a subset (only the ones left checked), unlike
    /// `renameAllNeedingCleanup`'s unconditional "every suggestion, as-is" sweep. A
    /// blank/whitespace-only name is a silent no-op for that row rather than failing
    /// the whole batch. Each name still goes through `uniqueProjectName` — two edited
    /// names can collide with each other or with an existing project just as easily as
    /// two raw heuristic suggestions can.
    public func renameProjectsBulk(_ renames: [(projectId: Int64, newName: String)]) async throws {
        guard !renames.isEmpty else { return }
        try await writer.write { conn in
            for (projectId, newName) in renames {
                let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let directory = try String.fetchOne(
                    conn, sql: "SELECT source_folder_path FROM projects WHERE id = ?", arguments: [projectId]
                )
                let unique = try Self.uniqueProjectName(trimmed, directory: directory, excludingId: projectId, conn: conn)
                try conn.execute(sql: "UPDATE projects SET name = ? WHERE id = ?", arguments: [unique, projectId])
            }
        }
    }

    /// Applies every current cleanup suggestion in one action, disambiguating each
    /// through the same `uniqueProjectName` path — collisions between suggestions are
    /// common (the "-model_files"/"-print_files" sibling-folder pair both cleaning to
    /// the same string), so blindly accepting everything without this would create
    /// duplicate project names.
    @discardableResult
    public func renameAllNeedingCleanup() async throws -> Int {
        let suggestions = try await projectsNeedingNameCleanup()
        guard !suggestions.isEmpty else { return 0 }
        try await writer.write { conn in
            for suggestion in suggestions {
                guard let id = suggestion.project.id else { continue }
                let unique = try Self.uniqueProjectName(
                    suggestion.suggestedName, directory: suggestion.project.sourceFolderPath, excludingId: id, conn: conn
                )
                try conn.execute(sql: "UPDATE projects SET name = ? WHERE id = ?", arguments: [unique, id])
            }
        }
        return suggestions.count
    }

    /// Disambiguates a name collision by leading with the parent folder's name and
    /// moving the colliding name into parentheses ("Root Board Game (Woodland
    /// Alliance)") — the parent is what actually identifies which kit a generic-
    /// sounding name came from. Falls back to a numeric suffix if there's no
    /// `directory` to derive a parent-folder qualifier from, or in the practically-
    /// never-happens case where even that collides too.
    /// Not `private` — `ProjectSuggestionService` also needs this same collision-safe
    /// naming when auto-creating a project from a folder, so it's shared at module
    /// (not just this type's) scope rather than duplicated.
    static func uniqueProjectName(_ name: String, directory: String?, excludingId: Int64?, conn: Database) throws -> String {
        guard try isProjectNameTaken(name, excludingId: excludingId, conn: conn) else { return name }

        var baseCandidate: String?
        if let directory {
            let parentFolderName = URL(fileURLWithPath: directory).deletingLastPathComponent().lastPathComponent
            let parentName = ProjectNaming.suggestCleanName(parentFolderName)
            let candidate = "\(parentName) (\(name))"
            if try !isProjectNameTaken(candidate, excludingId: excludingId, conn: conn) {
                return candidate
            }
            baseCandidate = candidate
        }

        var suffix = 2
        while true {
            let candidate = baseCandidate.map { "\($0) (\(suffix))" } ?? "\(name) (\(suffix))"
            if try !isProjectNameTaken(candidate, excludingId: excludingId, conn: conn) {
                return candidate
            }
            suffix += 1
        }
    }

    private static func isProjectNameTaken(_ name: String, excludingId: Int64?, conn: Database) throws -> Bool {
        if let excludingId {
            return try Int.fetchOne(
                conn, sql: "SELECT 1 FROM projects WHERE lower(name) = lower(?) AND id != ? LIMIT 1", arguments: [name, excludingId]
            ) != nil
        }
        return try Int.fetchOne(conn, sql: "SELECT 1 FROM projects WHERE lower(name) = lower(?) LIMIT 1", arguments: [name]) != nil
    }

    // MARK: - Merge

    /// Merges `sourceId` into `targetId`: every one of source's `project_files` rows
    /// moves to target (a file already in both keeps target's row, promoted to
    /// confirmed first if source had it confirmed — merging never silently downgrades a
    /// confirmed membership), source's own sub-projects are re-parented under target,
    /// and source itself is deleted. No-op (returns `false`) for a meaningless
    /// self-merge. `source_folder_path` (the folder-tracking column, UNIQUE) copies
    /// over to target only if target doesn't already have one of its own.
    @discardableResult
    public func mergeProjects(sourceId: Int64, intoTargetId targetId: Int64) async throws -> Bool {
        guard sourceId != targetId else { return false }
        try await writer.write { conn in
            try conn.execute(sql: """
                UPDATE project_files SET status = 'confirmed'
                WHERE project_id = ? AND status = 'suggested'
                  AND file_id IN (SELECT file_id FROM project_files WHERE project_id = ? AND status = 'confirmed')
                """, arguments: [targetId, sourceId])
            try conn.execute(sql: """
                UPDATE project_files SET project_id = ?
                WHERE project_id = ? AND file_id NOT IN (SELECT file_id FROM project_files WHERE project_id = ?)
                """, arguments: [targetId, sourceId, targetId])
            try conn.execute(sql: "DELETE FROM project_files WHERE project_id = ?", arguments: [sourceId])
            // A re-parented project that happens to equal targetId itself is excluded
            // (only possible if target was a *direct* child of source) — or this would
            // try to make target its own parent. If target itself was a child of
            // source, its parent_project_id already goes to NULL for free once source
            // is deleted (ON DELETE SET NULL), which is the sensible outcome.
            try conn.execute(
                sql: "UPDATE projects SET parent_project_id = ? WHERE parent_project_id = ? AND id != ?",
                arguments: [targetId, sourceId, targetId]
            )
            let sourceFolderPath = try String.fetchOne(
                conn, sql: "SELECT source_folder_path FROM projects WHERE id = ?", arguments: [sourceId]
            )
            // Source has to actually be deleted before target can take over its
            // source_folder_path — the column is UNIQUE, so both rows briefly holding
            // the same value would violate that constraint even though the end state
            // (one row, not two) is perfectly valid.
            try conn.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [sourceId])
            if let sourceFolderPath {
                try conn.execute(
                    sql: "UPDATE projects SET source_folder_path = ? WHERE id = ? AND source_folder_path IS NULL",
                    arguments: [sourceFolderPath, targetId]
                )
            }
        }
        return true
    }
}

public struct ProjectSummary: Sendable, Identifiable {
    public let project: Project
    public let fileCount: Int
    public let subprojectCount: Int
    public var id: Int64? { project.id }
}

public struct ProjectCardVisuals: Sendable {
    public let thumbnailPaths: [String]
    public let extensions: [String]
}

public struct ProjectRenameSuggestion: Sendable, Identifiable {
    public let project: Project
    public let suggestedName: String
    public var id: Int64? { project.id }
}
