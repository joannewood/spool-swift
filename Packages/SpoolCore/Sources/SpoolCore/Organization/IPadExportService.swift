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

        let destination = try makeDestinationDatabase(at: destinationFolder)

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

        let exported = try await source.read { conn in
            try Row.fetchAll(conn, sql: """
                SELECT DISTINCT f.id, f.path, f.thumbnail_path, p.name AS project_name
                FROM files f
                JOIN project_files pf ON pf.file_id = f.id
                JOIN projects p ON p.id = pf.project_id
                WHERE p.shared_with_ipad = 1 AND f.status = 'active'
                """)
        }

        for row in exported {
            let sourcePath: String = row["path"]
            let projectName: String = row["project_name"]
            let projectDir = filesDir.appendingPathComponent(sanitizedFolderName(projectName), isDirectory: true)
            try fileManager.createDirectory(at: projectDir, withIntermediateDirectories: true)
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let destURL = projectDir.appendingPathComponent(sourceURL.lastPathComponent)
            try? fileManager.removeItem(at: destURL)
            try? fileManager.copyItem(at: sourceURL, to: destURL)

            if let thumbnailName = row["thumbnail_path"] as String? {
                let thumbSourceURL = sourceThumbnailsDirectory.appendingPathComponent(thumbnailName)
                let thumbDestURL = thumbnailsDir.appendingPathComponent(thumbnailName)
                try? fileManager.removeItem(at: thumbDestURL)
                try? fileManager.copyItem(at: thumbSourceURL, to: thumbDestURL)
            }
        }

        let projectCount = try await destination.read { conn in try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM projects") ?? 0 }
        return Summary(projectCount: projectCount, fileCount: exported.count)
    }

    /// A fresh database file, full-rewrite each export — same schema/migrations as the
    /// real library (so `SearchService`/models work against it unmodified), but with
    /// FK enforcement off for this write-only connection (see the cycle note above).
    private static func makeDestinationDatabase(at destinationFolder: URL) throws -> any DatabaseWriter {
        let dbURL = destinationFolder.appendingPathComponent("library.sqlite")
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(atPath: dbURL.path + suffix)
        }

        var config = Configuration()
        config.foreignKeysEnabled = false
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction("normalize", argumentCount: 1, pure: true) { values in
                guard let text = String.fromDatabaseValue(values[0]) else { return nil }
                return SpoolTextNormalization.normalize(text)
            })
        }
        let destination = try DatabaseQueue(path: dbURL.path, configuration: config)
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        try migrator.migrate(destination)
        return destination
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
        let rows = try await source.read { conn in try Row.fetchAll(conn, sql: sql) }
        guard let first = rows.first else { return }
        let columns = Array(first.columnNames)
        // `Row` isn't `Sendable`; extract plain `DatabaseValue`s (which are) before
        // crossing into the `@Sendable` write closure below.
        let allValues: [[DatabaseValue]] = rows.map { Array($0.databaseValues) }
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
