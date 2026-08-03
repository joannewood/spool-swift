import Foundation
import GRDB

/// Suggests a project for any indexed file sitting in a "meaningful" subfolder,
/// ported faithfully from the source app's `relationship_suggest.py::suggest_folder_project`
/// (the folder-grouping heuristic actually lives in that file despite its name).
/// Matching/deduping is by the folder's real *path* (`projects.source_folder_path`),
/// not its current display name, so a later rename (by the user, via the app's
/// pencil-edit UI) never breaks future files in that same folder from finding the same
/// project. Membership inserts as `status = 'suggested'` via insert-or-ignore against
/// `project_files`' composite primary key, so re-running this (every ingest, live or
/// backfill) never reverts a user's confirm *or* reject — both already occupy that same
/// `(project_id, file_id)` row.
public struct ProjectSuggestionService: Sendable {
    /// A folder literally named one of these is just a model-file container, not a
    /// project's real identity (a common download/export convention:
    /// `<ProjectName>/files/widget.stl`) — fall back to the parent folder's identity
    /// instead, unless the generic folder sits directly in the watched root (no
    /// more-meaningful parent available). Derived from `ModelExtension.all` (not
    /// hardcoded) so a per-format export folder ("STL Files", "3MF", "STEP Files"...)
    /// is covered the same way a bare "files"/"cad" folder is — confirmed live in the
    /// source app: 36 real projects named nothing but a bare format string.
    private static let genericContainerNames: Set<String> = {
        var names: Set<String> = ["files", "file", "cad", "cad file", "cad files"]
        for ext in ModelExtension.all {
            names.insert(ext)
            names.insert("\(ext) file")
            names.insert("\(ext) files")
        }
        return names
    }()

    // "widget_stand!.stl" vs "Widget-Stand" must both reduce to "widgetstand" for the
    // single-file bare-name-match skip below — strips everything but letters/digits,
    // deliberately stricter than the underscore/hyphen-only normalization used for
    // generic-container-name matching.
    private static let nonAlnumRegex = try! NSRegularExpression(pattern: "[^a-z0-9]")
    private static let separatorToSpaceRegex = try! NSRegularExpression(pattern: "[_-]+")
    // "<kit>-model_files"/"<kit>-print_files" sibling top-level folders are really the
    // same kit split by file type — see `siblingModelPrintPath`.
    private static let modelPrintSuffixRegex = try! NSRegularExpression(
        pattern: #"^(.*)-(model|print)_files$"#, options: .caseInsensitive
    )
    // "Archive"/"Archive 2"/"Archive(2)" — a folder that exists purely to hold a batch
    // of unrelated zips together for compression, not a real kit grouping. Skipped when
    // walking up to find a wrapper-project parent (see `skipArchiveAncestors`).
    private static let archiveFolderRegex = try! NSRegularExpression(
        pattern: #"^archive\s*\(?\s*\d*\s*\)?$"#, options: .caseInsensitive
    )

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func suggestProject(forFileId fileId: Int64) async throws {
        guard let file = try await writer.read({ conn in try SpoolFile.fetchOne(conn, id: fileId) }) else { return }
        guard let root = try await writer.read({ conn in try WatchedRoot.fetchOne(conn, id: file.watchedRootId) })
        else { return }

        let containingFolder = URL(fileURLWithPath: file.path).deletingLastPathComponent().standardizedFileURL
        let rootURL = URL(fileURLWithPath: root.hostPath).standardizedFileURL
        guard containingFolder.path != rootURL.path else { return }

        // One write transaction for the whole thing: siblings are re-queried fresh
        // every call (not just the one file being ingested) so a folder that gets a
        // second file later correctly sweeps in a first file this same check
        // previously skipped — and two files landing in a brand-new folder at once (a
        // real possibility under live-watch concurrency) can't race into two projects.
        try await writer.write { conn in
            let siblingRows = try Row.fetchAll(
                conn, sql: "SELECT id, path FROM files WHERE status = 'active' AND path LIKE ?",
                arguments: ["\(containingFolder.path)/%"]
            )
            let siblings = siblingRows.filter { row in
                let path: String = row["path"]
                return (path as NSString).deletingLastPathComponent == containingFolder.path
            }
            guard !siblings.isEmpty else { return }

            let immediateFolderName = containingFolder.lastPathComponent
            // One exception to "even a lone file gets a project": if the folder holds
            // exactly one file and that file's own name is really just its immediate
            // folder's name again, a project of one adds nothing a plain file browse
            // doesn't already show ("Widget Stand/Widget Stand.stl" is self-
            // explanatory). Checked against the real immediate folder name, before the
            // generic-container-name substitution below.
            if siblings.count == 1 {
                let siblingPath: String = siblings[0]["path"]
                let stem = ((siblingPath as NSString).lastPathComponent as NSString).deletingPathExtension
                if Self.bareName(stem) == Self.bareName(immediateFolderName) {
                    return
                }
            }

            var matchDirectory = containingFolder
            var folderName = immediateFolderName
            if Self.isGenericContainerName(folderName) {
                let parentFolder = containingFolder.deletingLastPathComponent().standardizedFileURL
                if parentFolder.path != rootURL.path {
                    matchDirectory = parentFolder
                    folderName = parentFolder.lastPathComponent
                }
                // else: the generic-named folder sits directly in the watched root, so
                // there's no more-meaningful parent to fall back to — keep it.
            }
            folderName = ProjectNaming.cleanName(folderName)

            let projectId: Int64
            if let existing = try Project.filter(Column("source_folder_path") == matchDirectory.path).fetchOne(conn) {
                projectId = existing.id!
            } else if let siblingDirectory = Self.siblingModelPrintPath(matchDirectory.path),
                      let existing = try Project.filter(Column("source_folder_path") == siblingDirectory).fetchOne(conn) {
                projectId = existing.id!
            } else {
                let uniqueName = try ProjectService.uniqueProjectName(
                    folderName, directory: matchDirectory.path, excludingId: nil, conn: conn
                )
                let project = Project(name: uniqueName, sourceFolderPath: matchDirectory.path)
                projectId = try project.inserted(conn).id!
            }

            for sibling in siblings {
                let siblingId: Int64 = sibling["id"]
                try conn.execute(sql: """
                    INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'suggested')
                    ON CONFLICT (project_id, file_id) DO NOTHING
                    """, arguments: [projectId, siblingId])
            }

            try Self.maybeGroupUnderWrapper(projectId: projectId, matchDirectory: matchDirectory.path, root: root, conn: conn)
        }
    }

    // MARK: - Wrapper-project grouping

    /// A folder with 2+ existing sibling projects (sharing the same effective parent —
    /// see `skipArchiveAncestors`) gets that parent turned into a wrapper project
    /// nesting all of them, instead of staying flat forever — e.g. a kit's per-
    /// continent subfolders ("1_Europe", "2_Asia"...) each already get their own flat
    /// project via the rest of this type, but once there are 2+ of them the parent kit
    /// folder becomes a project of its own with the siblings re-parented under it.
    /// Deliberately conservative: fires only for 2+ children, not every level of
    /// nesting (confirmed live in the source app: nesting unconditionally created 82%
    /// wrapper projects with exactly one child — pure clutter). A project's own
    /// `parent_project_id` is only ever set here if it's still `NULL`, so a user's
    /// manual sub-project assignment is never silently overridden.
    private static func maybeGroupUnderWrapper(projectId: Int64, matchDirectory: String, root: WatchedRoot, conn: Database) throws {
        let parentDir = (matchDirectory as NSString).deletingLastPathComponent
        guard normalizedPath(parentDir) != normalizedPath(root.hostPath) else { return }
        let effectiveParent = skipArchiveAncestors(from: parentDir, rootHostPath: root.hostPath)
        guard normalizedPath(effectiveParent) != normalizedPath(root.hostPath) else { return }

        if let wrapper = try Project.filter(Column("source_folder_path") == effectiveParent).fetchOne(conn), let wrapperId = wrapper.id {
            try conn.execute(
                sql: "UPDATE projects SET parent_project_id = ? WHERE id = ? AND parent_project_id IS NULL",
                arguments: [wrapperId, projectId]
            )
            return
        }

        let candidateRows = try Row.fetchAll(
            conn, sql: "SELECT id, source_folder_path FROM projects WHERE source_folder_path LIKE ?",
            arguments: ["\(effectiveParent)/%"]
        )
        let siblingIds: [Int64] = candidateRows.compactMap { row in
            guard let path: String = row["source_folder_path"] else { return nil }
            let dir = (path as NSString).deletingLastPathComponent
            let effectiveSiblingParent = skipArchiveAncestors(from: dir, rootHostPath: root.hostPath)
            guard normalizedPath(effectiveSiblingParent) == normalizedPath(effectiveParent) else { return nil }
            return row["id"] as Int64
        }
        guard siblingIds.count >= 2 else { return }

        let wrapperName = try ProjectService.uniqueProjectName(
            wrapperProjectName(parentDir: effectiveParent, rootHostPath: root.hostPath),
            directory: effectiveParent, excludingId: nil, conn: conn
        )
        let wrapper = Project(name: wrapperName, sourceFolderPath: effectiveParent)
        let wrapperId = try wrapper.inserted(conn).id!

        for siblingId in siblingIds {
            try conn.execute(
                sql: "UPDATE projects SET parent_project_id = ? WHERE id = ? AND parent_project_id IS NULL",
                arguments: [wrapperId, siblingId]
            )
        }
    }

    /// Same "name too generic, use the parent instead" fallback already applied to leaf
    /// projects — a wrapper folder can be just as generic (e.g. a kit's own export
    /// folder is itself literally called "files").
    private static func wrapperProjectName(parentDir: String, rootHostPath: String) -> String {
        var name = (parentDir as NSString).lastPathComponent
        if isGenericContainerName(name) {
            let grandparent = (parentDir as NSString).deletingLastPathComponent
            if normalizedPath(grandparent) != normalizedPath(rootHostPath) {
                name = (grandparent as NSString).lastPathComponent
            }
        }
        return ProjectNaming.cleanName(name)
    }

    /// Walk up from `directory` past any 'Archive'/'Archive 2' folder in the chain.
    /// Stops at the watched root regardless (never walks above it).
    private static func skipArchiveAncestors(from directory: String, rootHostPath: String) -> String {
        var current = normalizedPath(directory)
        let root = normalizedPath(rootHostPath)
        while current != root, isArchiveFolderName((current as NSString).lastPathComponent) {
            current = (current as NSString).deletingLastPathComponent
        }
        return current
    }

    // MARK: - Small pure helpers

    /// If any single path component of `directory` ends in -model_files/-print_files,
    /// returns the path with that one component's suffix swapped (model<->print) and
    /// everything else — including any nested subfolder name after it — unchanged;
    /// else `nil`. A distinct Printables download convention from the generic-
    /// container-name one above: the *whole kit* (not just an export subfolder) is
    /// split into two sibling top-level folders by file type, so
    /// "<kit>-model_files/Widget" and "<kit>-print_files/Widget" are really the same
    /// "Widget" grouping, discovered from two different physical folders.
    static func siblingModelPrintPath(_ directory: String) -> String? {
        var parts = directory.components(separatedBy: "/")
        for (index, part) in parts.enumerated() {
            let ns = part as NSString
            guard let match = modelPrintSuffixRegex.firstMatch(in: part, range: NSRange(location: 0, length: ns.length))
            else { continue }
            let stem = ns.substring(with: match.range(at: 1))
            let kind = ns.substring(with: match.range(at: 2)).lowercased()
            let other = kind == "model" ? "print" : "model"
            parts[index] = "\(stem)-\(other)_files"
            return parts.joined(separator: "/")
        }
        return nil
    }

    static func bareName(_ name: String) -> String {
        let cleaned = ProjectNaming.cleanName(name).lowercased()
        let ns = cleaned as NSString
        return nonAlnumRegex.stringByReplacingMatches(in: cleaned, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    static func isGenericContainerName(_ name: String) -> Bool {
        let ns = name as NSString
        let normalized = separatorToSpaceRegex
            .stringByReplacingMatches(in: name, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
            .lowercased()
        return genericContainerNames.contains(normalized)
    }

    private static func isArchiveFolderName(_ name: String) -> Bool {
        let ns = name as NSString
        return archiveFolderRegex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) != nil
    }

    private static func normalizedPath(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
