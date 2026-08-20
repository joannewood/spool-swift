import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct SchemaTests {
    @Test func migrationCreatesAllTables() throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let tableNames = try db.writer.read { conn in
            try String.fetchAll(conn, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
        }
        let expected = [
            "watched_roots", "files", "tags", "file_tags", "projects", "project_files",
            "print_metadata", "relationships", "jobs", "zip_files", "sidecar_files",
            "print_log", "app_settings", "grdb_migrations",
        ]
        for table in expected {
            #expect(tableNames.contains(table), "missing table \(table)")
        }
    }

    @Test func appSettingsSingletonSeeded() throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let settings = try db.writer.read { conn in
            try AppSettings.fetchOne(conn, key: AppSettings.singletonId)
        }
        #expect(settings?.rescanIntervalSeconds == 300)
        #expect(settings?.rescanEnabled == true)
    }

    @Test func watchedRootRoundTrips() throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        var root = WatchedRoot(
            hostPath: "/Users/test/DropFolder",
            label: "Drop Folder",
            kind: .dropFolder,
            bookmarkData: Data([0x01, 0x02, 0x03])
        )
        try db.writer.write { conn in
            try root.insert(conn)
        }
        #expect(root.id != nil)

        let fetched = try db.writer.read { conn in
            try WatchedRoot.fetchOne(conn, id: root.id!)
        }
        #expect(fetched?.hostPath == "/Users/test/DropFolder")
        #expect(fetched?.kind == .dropFolder)
        #expect(fetched?.bookmarkData == Data([0x01, 0x02, 0x03]))
    }

    @Test func filenameNormalizedTriggerTreatsHyphenUnderscoreSpaceAsEquivalent() throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        var root = WatchedRoot(hostPath: "/Users/test/Lib", label: "Library", kind: .library, bookmarkData: Data())
        try db.writer.write { conn in try root.insert(conn) }

        var file = SpoolFile(
            watchedRootId: root.id!,
            path: "/Users/test/Lib/cake_stand.stl",
            filename: "cake_stand.stl",
            ext: "stl",
            sizeBytes: 1024
        )
        try db.writer.write { conn in try file.insert(conn) }

        let normalized = try db.writer.read { conn in
            try String.fetchOne(conn, sql: "SELECT filename_normalized FROM files WHERE id = ?", arguments: [file.id])
        }
        #expect(normalized == "cake stand.stl")

        // A search for "cake stand" should match via the normalized column, treating
        // the underscore in the real filename as equivalent to a space.
        let matchCount = try db.writer.read { conn in
            try Int.fetchOne(conn, sql: """
                SELECT COUNT(*) FROM files WHERE filename_normalized LIKE '%' || normalize(?) || '%'
                """, arguments: ["cake stand"])
        }
        #expect(matchCount == 1)
    }

    /// Reproduces a real bug found live: v5 only creates a gallery row going forward
    /// (via `FileGalleryService`, called from the ingest/render job handlers) — a file
    /// rendered *before* that migration ran keeps its `thumbnail_path` but never gets a
    /// `file_gallery_images` row, so `FileGalleryCarousel` (which only reads the
    /// gallery table) shows a placeholder instead of the perfectly good thumbnail that
    /// already exists on disk. Confirmed live against a real ~13,500-file library —
    /// every single file was affected. v6 backfills this; this test builds a database
    /// stopped right after v5 (simulating an install that already has real files with
    /// thumbnails but hasn't run v6 yet), then lets the migrator continue, to prove the
    /// backfill actually runs against realistic pre-existing data, not just fresh rows.
    @Test func v6BackfillsGalleryRowsForFilesRenderedBeforeTheGalleryFeatureExisted() throws {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction("normalize", argumentCount: 1, pure: true) { values in
                String.fromDatabaseValue(values[0]).map(SpoolTextNormalization.normalize)
            })
        }
        let dbQueue = try DatabaseQueue(configuration: config)
        try migrator.migrate(dbQueue, upTo: "v5_file_gallery_images")

        let rootId: Int64 = try dbQueue.write { conn in
            try WatchedRoot(hostPath: "/Users/test/Lib", label: "Library", kind: .library, bookmarkData: Data())
                .inserted(conn).id!
        }
        let fileId: Int64 = try dbQueue.write { conn in
            try SpoolFile(
                watchedRootId: rootId, path: "/Users/test/Lib/old.stl", filename: "old.stl", ext: "stl", sizeBytes: 1,
                thumbnailPath: "42.png", renderStatus: .done
            ).inserted(conn).id!
        }
        // Pre-v6: rendered long ago, no gallery row, matching every real file found live.
        let preMigrationImageCount = try dbQueue.read { conn in
            try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM file_gallery_images WHERE file_id = ?", arguments: [fileId])
        }
        #expect(preMigrationImageCount == 0)

        try migrator.migrate(dbQueue)

        let image = try dbQueue.read { conn in
            try FileGalleryImage.fetchOne(conn, sql: "SELECT * FROM file_gallery_images WHERE file_id = ?", arguments: [fileId])
        }
        #expect(image?.kind == .rendered)
        #expect(image?.thumbnailPath == "42.png")
        let file = try dbQueue.read { conn in try SpoolFile.fetchOne(conn, id: fileId) }
        #expect(file?.activeGalleryImageId == image?.id)
    }

    @Test func relationshipRejectsSelfReference() throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        var root = WatchedRoot(hostPath: "/Users/test/Lib", label: "Library", kind: .library, bookmarkData: Data())
        try db.writer.write { conn in try root.insert(conn) }
        var file = SpoolFile(watchedRootId: root.id!, path: "/a.stl", filename: "a.stl", ext: "stl", sizeBytes: 1)
        try db.writer.write { conn in try file.insert(conn) }

        var rel = Relationship(fromFileId: file.id!, toFileId: file.id!, type: .duplicateOf)
        #expect(throws: (any Error).self) {
            try db.writer.write { conn in try rel.insert(conn) }
        }
    }
}
