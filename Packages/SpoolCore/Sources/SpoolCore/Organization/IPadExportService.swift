import Foundation
import GRDB

/// Produces a self-contained, curated mirror of the library for the iPad companion
/// app: a relationally-consistent subset SQLite database (the exact same schema/
/// migrations as the real one, populated with only the projects marked
/// `shared_with_ipad` and everything those files need to display), plus copies of
/// their thumbnails and model files, all in one destination folder — typically
/// synced to an iPad via iCloud Drive. The iPad only needs to be granted access to
/// this one folder; it never sees the real watched roots.
///
/// Full-rewrite on every run rather than incremental diffing: these are small,
/// deliberately curated subsets (a handful of shared projects), not the whole
/// library, so the simplicity is worth far more than the write savings would be.
public enum IPadExportService {
    public struct ExportError: Error, CustomStringConvertible {
        let message: String
        public var description: String { message }
    }

    public struct Summary: Equatable, Sendable {
        public var projectCount = 0
        public var fileCount = 0
    }

    /// - Parameters:
    ///   - source: the real library's reader (a `DatabasePool` in the running app, an
    ///     in-memory `DatabaseQueue` in tests).
    ///   - sourceThumbnailsDirectory: where `files.thumbnail_path` filenames resolve
    ///     to on disk in the source library.
    ///   - destinationFolder: the granted, already-resolved folder to export into.
    @discardableResult
    public static func export(
        from source: any DatabaseReader,
        sourceThumbnailsDirectory: URL,
        to destinationFolder: URL
    ) async throws -> Summary {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let thumbnailsDir = destinationFolder.appendingPathComponent("Thumbnails", isDirectory: true)
        let filesDir = destinationFolder.appendingPathComponent("Files", isDirectory: true)
        try fileManager.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: filesDir, withIntermediateDirectories: true)

        let (destination, tempDatabaseURL) = try makeDestinationDatabase(at: destinationFolder)

        // Dependency order matters for FK-enforced tables in general, but
        // `files.active_gallery_image_id` and `file_gallery_images.file_id` form a
        // genuine cycle (each references the other) — `foreignKeysEnabled = false` on
        // this write-only connection (see `makeDestinationDatabase`) sidesteps needing
        // a null-then-patch dance for that one column. A later reader (the iPad's own
        // `openReadOnly`) opens its own connection with its own enforcement setting;
        // this one only affects how the file gets written.
        try await copyRows(
            sql: "SELECT * FROM projects WHERE shared_with_ipad = 1",
            table: "projects", from: source, to: destination
        )
        try await copyRows(
            sql: """
                SELECT DISTINCT f.* FROM files f
                JOIN project_files pf ON pf.file_id = f.id
                JOIN projects p ON p.id = pf.project_id
                WHERE p.shared_with_ipad = 1 AND f.status = 'active'
                """,
            table: "files", from: source, to: destination
        )
        try await copyRows(
            sql: """
                SELECT DISTINCT wr.* FROM watched_roots wr
                JOIN files f ON f.watched_root_id = wr.id
                JOIN project_files pf ON pf.file_id = f.id
                JOIN projects p ON p.id = pf.project_id
                WHERE p.shared_with_ipad = 1 AND f.status = 'active'
                """,
            table: "watched_roots", from: source, to: destination
        )
        try await copyRows(
            sql: """
                SELECT pf.* FROM project_files pf
                JOIN projects p ON p.id = pf.project_id
                JOIN files f ON f.id = pf.file_id
                WHERE p.shared_with_ipad = 1 AND f.status = 'active'
                """,
            table: "project_files", from: source, to: destination
        )
        try await copyRows(
            sql: """
                SELECT DISTINCT t.* FROM tags t
                JOIN file_tags ft ON ft.tag_id = t.id
                JOIN files f ON f.id = ft.file_id
                JOIN project_files pf ON pf.file_id = f.id
                JOIN projects p ON p.id = pf.project_id
                WHERE p.shared_with_ipad = 1 AND f.status = 'active'
                """,
            table: "tags", from: source, to: destination
        )
        try await copyRows(
            sql: """
                SELECT ft.* FROM file_tags ft
                JOIN files f ON f.id = ft.file_id
                JOIN project_files pf ON pf.file_id = f.id
                JOIN projects p ON p.id = pf.project_id
                WHERE p.shared_with_ipad = 1 AND f.status = 'active'
                """,
            table: "file_tags", from: source, to: destination
        )
        try await copyRows(
            sql: """
                SELECT pm.* FROM print_metadata pm
                JOIN files f ON f.id = pm.file_id
                JOIN project_files pf ON pf.file_id = f.id
                JOIN projects p ON p.id = pf.project_id
                WHERE p.shared_with_ipad = 1 AND f.status = 'active'
                """,
            table: "print_metadata", from: source, to: destination
        )
        try await copyRows(
            sql: """
                SELECT DISTINCT fgi.* FROM file_gallery_images fgi
                JOIN files f ON f.id = fgi.file_id
                JOIN project_files pf ON pf.file_id = f.id
                JOIN projects p ON p.id = pf.project_id
                WHERE p.shared_with_ipad = 1 AND f.status = 'active'
                """,
            table: "file_gallery_images", from: source, to: destination
        )

        // `Row` isn't `Sendable`, so convert to plain values inside the read closure.
        let exported: [ExportedFile] = try await source.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT DISTINCT f.id, f.path, f.thumbnail_path, p.name AS project_name
                FROM files f
                JOIN project_files pf ON pf.file_id = f.id
                JOIN projects p ON p.id = pf.project_id
                WHERE p.shared_with_ipad = 1 AND f.status = 'active'
                """).map { row in
                ExportedFile(path: row["path"], thumbnailPath: row["thumbnail_path"], projectName: row["project_name"])
            }
        }

        for file in exported {
            let sourcePath = file.path
            let projectName = file.projectName
            let projectDir = filesDir.appendingPathComponent(sanitizedFolderName(projectName), isDirectory: true)
            try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let destURL = projectDir.appendingPathComponent(sourceURL.lastPathComponent)
            try? fileManager.removeItem(at: destURL)
            try? fileManager.copyItem(at: sourceURL, to: destURL)

            if let thumbnailName = file.thumbnailPath {
                let thumbSourceURL = sourceThumbnailsDirectory.appendingPathComponent(thumbnailName)
                let thumbDestURL = thumbnailsDir.appendingPathComponent(thumbnailName)
                try? fileManager.removeItem(at: thumbDestURL)
                try? fileManager.copyItem(at: thumbSourceURL, to: thumbDestURL)
            }
        }

        let projectCount = try await destination.read { conn in try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM projects") ?? 0 }

        // Atomically swap the finished, fully-populated database into place as the very
        // last step — never delete-and-recreate `library.sqlite` at its real path
        // directly (the previous approach). The iPad reads this same path at arbitrary
        // times via iCloud sync, with no coordination with this export; an in-place
        // delete+recreate left a real window where that read could hit a missing or
        // half-written file ("disk I/O error", confirmed live on a real iPad). Building
        // at a temp path first and using `replaceItemAt` means the iPad only ever sees
        // either the old complete file or the new complete file, never neither.
        let finalDatabaseURL = destinationFolder.appendingPathComponent("library.sqlite")
        // Stale `-wal`/`-shm` siblings can only be left behind by a pre-fix export (this
        // temp-file approach never produces its own, since the temp database forces
        // `journal_mode = DELETE`) — harmless to leave, but clean them up if found.
        for suffix in ["-wal", "-shm"] {
            try? fileManager.removeItem(atPath: finalDatabaseURL.path + suffix)
        }
        // Deliberately the raw POSIX `rename()`, not `FileManager.replaceItemAt` — tried
        // that first and it still reproduced the exact crash this fix exists for, in a
        // controlled local test with no iCloud involved (confirmed via
        // `reExportDoesNotBreakAnAlreadyOpenReader`). `replaceItemAt`'s "safe save"
        // semantics don't guarantee a plain directory-entry swap the way `rename(2)`
        // does — a reader that already has the old path open can still see its content
        // change out from under it. Plain `rename()` only ever repoints the directory
        // entry: an already-open reader keeps its old, still-valid file descriptor
        // throughout, which is exactly the guarantee this needs.
        let renameResult = tempDatabaseURL.path.withCString { tempPath in
            finalDatabaseURL.path.withCString { finalPath in
                rename(tempPath, finalPath)
            }
        }
        guard renameResult == 0 else {
            throw ExportError(message: "rename() failed swapping the export database into place: errno \(errno)")
        }

        return Summary(projectCount: projectCount, fileCount: exported.count)
    }

    private struct ExportedFile: Sendable {
        let path: String
        let thumbnailPath: String?
        let projectName: String
    }

    /// A fresh database file, full-rewrite each export — same schema/migrations as the
    /// real library (so `SearchService`/models work against it unmodified), but with
    /// FK enforcement off for this write-only connection (see the cycle note above).
    /// Builds into a fresh temp file, never the real `library.sqlite` path directly —
    /// see the rename in `export()` for why. `journal_mode = DELETE` keeps everything in
    /// that one file (no `-wal`/`-shm` siblings), so the final swap-into-place only ever
    /// has to move a single file.
    private static func makeDestinationDatabase(at destinationFolder: URL) throws -> (writer: any DatabaseWriter, tempURL: URL) {
        let fileManager = FileManager.default
        // Clean up any temp file left behind by an export that crashed before renaming.
        if let existing = try? fileManager.contentsOfDirectory(at: destinationFolder, includingPropertiesForKeys: nil) {
            for url in existing where url.lastPathComponent.hasPrefix(".library.sqlite.tmp-") {
                try? fileManager.removeItem(at: url)
            }
        }
        let tempURL = destinationFolder.appendingPathComponent(".library.sqlite.tmp-\(UUID().uuidString)")

        var config = Configuration()
        config.foreignKeysEnabled = false
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
            db.add(function: DatabaseFunction("normalize", argumentCount: 1, pure: true) { values in
                guard let text = String.fromDatabaseValue(values[0]) else { return nil }
                return SpoolTextNormalization.normalize(text)
            })
        }
        let destination = try DatabaseQueue(path: tempURL.path, configuration: config)
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(destination)
        return (destination, tempURL)
    }

    /// Generic fetch-then-insert copy between two independent connections (possibly to
    /// two different files, possibly one in-memory) — deliberately not `ATTACH
    /// DATABASE`, which needs a real on-disk path on both sides and wouldn't work for
    /// an in-memory source (tests use `SQLiteSpoolDatabase(path: nil)`, matching this
    /// package's established test convention). Column-agnostic (reads whatever
    /// `sql` selects and inserts it verbatim, ids included) so it stays correct as the
    /// schema evolves instead of needing a hand-maintained column list per table.
    private static func copyRows(
        sql: String, table: String, from source: any DatabaseReader, to destination: any DatabaseWriter
    ) async throws {
        // `Row` isn't `Sendable`; extract the column names and plain `DatabaseValue`s
        // (which are) inside the read closure, before anything crosses an await.
        let (columns, allValues): ([String], [[DatabaseValue]]) = try await source.read { conn in
            let rows = try Row.fetchAll(conn, sql: sql)
            return (rows.first.map { Array($0.columnNames) } ?? [], rows.map { Array($0.databaseValues) })
        }
        guard !columns.isEmpty else { return }
        let placeholders = columns.map { _ in "?" }.joined(separator: ", ")
        let insertSQL = "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
        try await destination.write { conn in
            for values in allValues {
                try conn.execute(sql: insertSQL, arguments: StatementArguments(values))
            }
        }
    }

    /// Public so the iPad browsing code can reconstruct exactly where a given file's
    /// copy landed (`Files/<sanitizedFolderName(project.name)>/<file.filename>`)
    /// without duplicating this logic and risking it drifting out of sync.
    public static func sanitizedFolderName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }
}
