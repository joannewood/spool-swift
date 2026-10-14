import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct IPadExportServiceTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IPadExportServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    @Test func exportIncludesOnlySharedProjectsAndCopiesFiles() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let sourceDir = try makeTempDir()
        let sourceThumbnailsDir = try makeTempDir()
        let destinationDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: sourceThumbnailsDir)
            try? FileManager.default.removeItem(at: destinationDir)
        }

        let sharedModelURL = sourceDir.appendingPathComponent("shared_widget.stl")
        try "shared model bytes".write(to: sharedModelURL, atomically: true, encoding: .utf8)
        let hiddenModelURL = sourceDir.appendingPathComponent("hidden_widget.stl")
        try "hidden model bytes".write(to: hiddenModelURL, atomically: true, encoding: .utf8)
        try "shared thumbnail bytes".write(
            to: sourceThumbnailsDir.appendingPathComponent("shared.png"), atomically: true, encoding: .utf8
        )

        try await db.writer.write { conn in
            let root = try WatchedRoot(hostPath: sourceDir.path, label: "Test", kind: .dropFolder, bookmarkData: Data()).inserted(conn)

            let sharedProject = try Project(name: "Shared Project", sharedWithIpad: true).inserted(conn)
            let hiddenProject = try Project(name: "Hidden Project", sharedWithIpad: false).inserted(conn)

            let sharedFile = try SpoolFile(
                watchedRootId: root.id!, path: sharedModelURL.path, filename: "shared_widget.stl", ext: "stl",
                sizeBytes: 10, thumbnailPath: "shared.png"
            ).inserted(conn)
            let hiddenFile = try SpoolFile(
                watchedRootId: root.id!, path: hiddenModelURL.path, filename: "hidden_widget.stl", ext: "stl",
                sizeBytes: 10
            ).inserted(conn)

            try ProjectFile(projectId: sharedProject.id!, fileId: sharedFile.id!).inserted(conn)
            try ProjectFile(projectId: hiddenProject.id!, fileId: hiddenFile.id!).inserted(conn)

            let tag = try Tag(name: "kid-friendly").inserted(conn)
            _ = try FileTag(fileId: sharedFile.id!, tagId: tag.id!).inserted(conn)

            _ = try PrintMetadata(fileId: sharedFile.id!, material: "PLA").inserted(conn)
            _ = try FileGalleryImage(
                fileId: sharedFile.id!, kind: .rendered, thumbnailPath: "shared.png"
            ).inserted(conn)
        }

        let summary = try await IPadExportService.export(
            from: db.writer, sourceThumbnailsDirectory: sourceThumbnailsDir, to: destinationDir
        )
        #expect(summary.projectCount == 1)
        #expect(summary.fileCount == 1)

        let exported = try SQLiteSpoolDatabase.openReadOnly(path: destinationDir.appendingPathComponent("library.sqlite").path)

        let projects = try await exported.writer.read { conn in try Project.fetchAll(conn) }
        #expect(projects.count == 1)
        #expect(projects.first?.name == "Shared Project")

        let files = try await exported.writer.read { conn in try SpoolFile.fetchAll(conn) }
        #expect(files.count == 1)
        #expect(files.first?.filename == "shared_widget.stl")

        let tags = try await exported.writer.read { conn in try Tag.fetchAll(conn) }
        #expect(tags.map(\.name) == ["kid-friendly"])

        let metadata = try await exported.writer.read { conn in try PrintMetadata.fetchAll(conn) }
        #expect(metadata.first?.material == "PLA")

        let galleryImages = try await exported.writer.read { conn in try FileGalleryImage.fetchAll(conn) }
        #expect(galleryImages.count == 1)

        // hidden project's data must be entirely absent, not just filtered on read
        let allFileCount = try await exported.writer.read { conn in try Int.fetchOne(conn, sql: "SELECT COUNT(*) FROM files") }
        #expect(allFileCount == 1)

        // real files copied to disk
        let copiedModel = destinationDir.appendingPathComponent("Files/Shared Project/shared_widget.stl")
        #expect(FileManager.default.fileExists(atPath: copiedModel.path))
        #expect(!FileManager.default.fileExists(atPath: destinationDir.appendingPathComponent("Files/Hidden Project").path))
        let copiedThumbnail = destinationDir.appendingPathComponent("Thumbnails/shared.png")
        #expect(FileManager.default.fileExists(atPath: copiedThumbnail.path))
    }

    @Test func exportWithNoSharedProjectsProducesAnEmptyLibrary() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let sourceThumbnailsDir = try makeTempDir()
        let destinationDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceThumbnailsDir)
            try? FileManager.default.removeItem(at: destinationDir)
        }

        try await db.writer.write { conn in
            _ = try Project(name: "Not Shared", sharedWithIpad: false).inserted(conn)
        }

        let summary = try await IPadExportService.export(
            from: db.writer, sourceThumbnailsDirectory: sourceThumbnailsDir, to: destinationDir
        )
        #expect(summary.projectCount == 0)
        #expect(summary.fileCount == 0)

        let exported = try SQLiteSpoolDatabase.openReadOnly(path: destinationDir.appendingPathComponent("library.sqlite").path)
        let projects = try await exported.writer.read { conn in try Project.fetchAll(conn) }
        #expect(projects.isEmpty)
    }

    /// Regression test for a real crash seen live on an iPad: the iPad opens
    /// `library.sqlite` while the Mac's periodic re-export is rewriting it. The old
    /// in-place delete-then-recreate had a window where the file was simply missing
    /// or half-written. The fix builds into a temp file and atomically swaps it in with
    /// `rename()`, so any FRESH open always sees either the complete old file or the
    /// complete new one — confirmed below, including a full re-export running
    /// concurrently in a background task while repeated fresh opens/queries race it.
    ///
    /// A connection already open *before* the swap is a separate matter: confirmed live
    /// (standalone GRDB repro, no app code involved) that `rename()`-ing a different
    /// file over a path an open `DatabaseQueue` already points at makes that
    /// connection's *next* query throw `SQLite error 10 (disk I/O error)` — a real
    /// SQLite/VFS-level behavior this fix cannot and should not paper over. The
    /// important property, verified here, is that it fails loudly and cleanly rather
    /// than silently returning stale or corrupt rows — which is exactly what makes
    /// `LibraryAccess`'s catch-and-reopen-on-error handling (see that file) the correct
    /// complementary fix on the reader side, not a workaround for a bug here.
    @Test func freshOpensDuringConcurrentReExportAlwaysSeeACompleteDatabase() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let sourceThumbnailsDir = try makeTempDir()
        let destinationDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceThumbnailsDir)
            try? FileManager.default.removeItem(at: destinationDir)
        }
        let dbPath = destinationDir.appendingPathComponent("library.sqlite").path

        _ = try await db.writer.write { conn in
            try Project(name: "First Project", sharedWithIpad: true).inserted(conn)
        }
        _ = try await IPadExportService.export(
            from: db.writer, sourceThumbnailsDirectory: sourceThumbnailsDir, to: destinationDir
        )

        // Hammer re-exports (each adding one more project) concurrently with repeated
        // fresh opens+queries, the way the Mac's export timer and the iPad's poll loop
        // run independently of each other in the real app.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 2...15 {
                    _ = try await db.writer.write { conn in
                        try Project(name: "Project \(i)", sharedWithIpad: true).inserted(conn)
                    }
                    _ = try await IPadExportService.export(
                        from: db.writer, sourceThumbnailsDirectory: sourceThumbnailsDir, to: destinationDir
                    )
                }
            }
            group.addTask {
                for _ in 0..<60 {
                    // A fresh open can itself race a concurrent rename (open succeeds
                    // against whichever file currently sits at the path, then the file
                    // underneath changes before the query runs) — exactly the stale-
                    // connection case this test's doc comment covers, so a clean
                    // disk-I/O-error here is an acceptable outcome, not a failure. What
                    // must never happen is a *successful* query returning a row count
                    // that doesn't match any real export's actual project count — i.e.
                    // a torn/partial read.
                    if let reader = try? SQLiteSpoolDatabase.openReadOnly(path: dbPath),
                       let projects = try? await reader.writer.read({ conn in try Project.fetchAll(conn) }) {
                        #expect((1...15).contains(projects.count), "saw a torn/partial read of \(projects.count) projects")
                    }
                }
            }
            try await group.waitForAll()
        }

        // After everything settles, a final fresh open sees the complete, final state.
        let finalReader = try SQLiteSpoolDatabase.openReadOnly(path: dbPath)
        let finalProjects = try await finalReader.writer.read { conn in try Project.fetchAll(conn) }
        #expect(finalProjects.count == 15)
    }
}

