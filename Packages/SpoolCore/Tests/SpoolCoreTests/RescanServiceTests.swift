import Foundation
import GRDB
import Testing
@testable import SpoolCore

private actor RescanRecordingEnqueuer: JobEnqueuer {
    private(set) var calls: [(fileId: Int64?, jobType: JobType)] = []

    func enqueue(fileId: Int64?, zipFileId: Int64?, jobType: JobType) async throws -> Job {
        calls.append((fileId, jobType))
        return Job(fileId: fileId, zipFileId: zipFileId, jobType: jobType)
    }
}

@Suite struct RescanServiceTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RescanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private func makeRoot(_ db: SQLiteSpoolDatabase, kind: RootKind = .library, hostPath: String = "/tmp/rescan-root") async throws -> WatchedRoot {
        let root = WatchedRoot(hostPath: hostPath, label: "Test", kind: kind, bookmarkData: Data())
        return try await db.writer.write { conn in try root.inserted(conn) }
    }

    private func makeServices(_ db: SQLiteSpoolDatabase) -> (backfill: BackfillService, rescan: RescanService, enqueuer: RescanRecordingEnqueuer) {
        let enqueuer = RescanRecordingEnqueuer()
        let backfill = BackfillService(writer: db.writer, enqueuer: enqueuer)
        let rescan = RescanService(writer: db.writer, enqueuer: enqueuer, backfill: backfill)
        return (backfill, rescan, enqueuer)
    }

    private func getFile(_ db: SQLiteSpoolDatabase, filename: String) async throws -> SpoolFile? {
        try await db.writer.read { conn in
            try SpoolFile.filter(Column("filename") == filename).fetchOne(conn)
        }
    }

    /// The real app hashes a newly-staged file asynchronously via `IngestJobHandler`,
    /// once the job queue gets to the `.ingest` job `rescan.run`/`backfill.run` enqueue
    /// (see `IngestJobHandler`'s own doc comment on the ingest→hash→render split). These
    /// unit tests use a plain recording stub instead of a real `JobQueue`, so any test
    /// whose assertions depend on a file already having its real `content_hash` (move
    /// detection, or just checking the hash directly) has to drive that catch-up step
    /// itself — this runs every not-yet-processed `.ingest` call through a real handler,
    /// exactly what the async queue would do on its own between rescan/backfill passes.
    private func drainNewIngestJobs(enqueuer: RescanRecordingEnqueuer, writer: any DatabaseWriter, processedCount: inout Int) async throws {
        let allCalls = await enqueuer.calls
        let newCalls = allCalls.dropFirst(processedCount)
        processedCount = allCalls.count
        let handler = IngestJobHandler(writer: writer, enqueuer: enqueuer)
        for call in newCalls where call.jobType == .ingest {
            try await handler.handle(Job(fileId: call.fileId, jobType: .ingest))
        }
    }

    @Test func rescanDiscoversNewFile() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try "geometry".write(to: tempDir.appendingPathComponent("widget.stl"), atomically: true, encoding: .utf8)

        let (_, rescan, enqueuer) = makeServices(db)
        try await rescan.run(root: library, rootURL: tempDir)
        var processed = 0
        try await drainNewIngestJobs(enqueuer: enqueuer, writer: db.writer, processedCount: &processed)

        let row = try await getFile(db, filename: "widget.stl")
        #expect(row?.status == .active)
        #expect(row?.contentHash != nil)
        #expect(row?.mtime != nil)
    }

    @Test func rescanMarksRemovedFileMissing() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("widget.stl")
        try "geometry".write(to: path, atomically: true, encoding: .utf8)

        let (_, rescan, _) = makeServices(db)
        try await rescan.run(root: library, rootURL: tempDir)

        try FileManager.default.removeItem(at: path)
        try await rescan.run(root: library, rootURL: tempDir)

        let row = try await getFile(db, filename: "widget.stl")
        #expect(row?.status == .missing)
    }

    @Test func rescanRevivesMissingFileWithUnchangedContent() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("widget.stl")
        try "geometry".write(to: path, atomically: true, encoding: .utf8)

        let (_, rescan, _) = makeServices(db)
        try await rescan.run(root: library, rootURL: tempDir)
        let originalHash = try await getFile(db, filename: "widget.stl")?.contentHash

        try FileManager.default.removeItem(at: path)
        try await rescan.run(root: library, rootURL: tempDir)
        #expect(try await getFile(db, filename: "widget.stl")?.status == .missing)

        try "geometry".write(to: path, atomically: true, encoding: .utf8) // same bytes, reappears at the same path
        try await rescan.run(root: library, rootURL: tempDir)

        let row = try await getFile(db, filename: "widget.stl")
        #expect(row?.status == .active)
        #expect(row?.contentHash == originalHash)
    }

    @Test func rescanRehashesOnRealContentChange() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("widget.stl")
        try "geometry-v1".write(to: path, atomically: true, encoding: .utf8)

        let (_, rescan, enqueuer) = makeServices(db)
        try await rescan.run(root: library, rootURL: tempDir)
        let before = try await getFile(db, filename: "widget.stl")!

        // simulate a render having already completed, so we can prove it gets reset
        _ = try await db.writer.write { conn in
            try conn.execute(
                sql: "UPDATE files SET render_status = 'done', thumbnail_path = ?, bbox_x = 1, is_manifold = 1 WHERE id = ?",
                arguments: ["42.png", before.id]
            )
        }

        try await Task.sleep(nanoseconds: 1_100_000_000) // comfortably clear the mtime fixture's 1-second threshold
        try "geometry-v2-different-content".write(to: path, atomically: true, encoding: .utf8)
        try await rescan.run(root: library, rootURL: tempDir)

        let after = try await getFile(db, filename: "widget.stl")!
        #expect(after.contentHash != before.contentHash)
        #expect(after.renderStatus == .pending)
        #expect(after.thumbnailPath == nil)
        #expect(after.bboxX == nil)
        #expect(after.isManifold == nil)

        let calls = await enqueuer.calls
        #expect(calls.contains { $0.fileId == before.id && $0.jobType == .render }, "a fresh render job was enqueued")
    }

    @Test func rescanTouchOnlyDoesNotTriggerRerender() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("widget.stl")
        try "geometry".write(to: path, atomically: true, encoding: .utf8)

        let (_, rescan, enqueuer) = makeServices(db)
        var processed = 0
        try await rescan.run(root: library, rootURL: tempDir)
        try await drainNewIngestJobs(enqueuer: enqueuer, writer: db.writer, processedCount: &processed)
        let before = try await getFile(db, filename: "widget.stl")!

        _ = try await db.writer.write { conn in
            try conn.execute(
                sql: "UPDATE files SET render_status = 'done', thumbnail_path = ? WHERE id = ?",
                arguments: ["42.png", before.id]
            )
        }
        // one 'render' job already exists from the initial discovery above (enqueued by
        // IngestJobHandler once it hashed the file) — that's correct and expected; what
        // we're checking is that the touch-only rescan below doesn't add a second one.
        let renderJobsBefore = await enqueuer.calls.filter { $0.fileId == before.id && $0.jobType == .render }.count
        #expect(renderJobsBefore == 1)

        // bump mtime only, content identical
        let future = Date().addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: path.path)
        try await rescan.run(root: library, rootURL: tempDir)
        try await drainNewIngestJobs(enqueuer: enqueuer, writer: db.writer, processedCount: &processed)

        let after = try await getFile(db, filename: "widget.stl")!
        #expect(after.contentHash == before.contentHash)
        #expect(after.renderStatus == .done)
        #expect(after.thumbnailPath == "42.png")

        let renderJobsAfter = await enqueuer.calls.filter { $0.fileId == before.id && $0.jobType == .render }.count
        #expect(renderJobsAfter == renderJobsBefore, "no spurious re-render job")
    }

    @Test func rescanDetectsMovedFileAndPreservesTags() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("widget.stl")
        try "geometry".write(to: path, atomically: true, encoding: .utf8)

        let (_, rescan, enqueuer) = makeServices(db)
        var processed = 0
        try await rescan.run(root: library, rootURL: tempDir)
        // move-detection only considers rows with a real content_hash — need the
        // deferred ingest job to have actually hashed this file first.
        try await drainNewIngestJobs(enqueuer: enqueuer, writer: db.writer, processedCount: &processed)
        let before = try await getFile(db, filename: "widget.stl")!

        let tagId = try await db.writer.write { conn -> Int64 in
            try conn.execute(sql: "INSERT INTO tags (name) VALUES ('kept')")
            let id = conn.lastInsertedRowID
            try conn.execute(sql: "INSERT INTO file_tags (file_id, tag_id) VALUES (?, ?)", arguments: [before.id, id])
            return id
        }

        let newDir = tempDir.appendingPathComponent("renamed_subfolder")
        try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
        let newPath = newDir.appendingPathComponent("widget-renamed.stl")
        try FileManager.default.moveItem(at: path, to: newPath)
        try await rescan.run(root: library, rootURL: tempDir)

        // the old filename is gone, no longer resolvable by that name
        #expect(try await getFile(db, filename: "widget.stl") == nil)

        let row = try await getFile(db, filename: "widget-renamed.stl")
        #expect(row != nil)
        #expect(row?.id == before.id, "same row, not a new one")
        #expect(row?.path == newPath.path)
        #expect(row?.status == .active)
        #expect(row?.contentHash == before.contentHash, "unchanged content, no re-hash needed")

        let totalFiles = try await db.writer.read { conn in
            try Int.fetchOne(conn, sql: "SELECT count(*) FROM files WHERE watched_root_id = ?", arguments: [library.id])
        }
        #expect(totalFiles == 1, "no duplicate row left behind")
        let tagCount = try await db.writer.read { conn in
            try Int.fetchOne(conn, sql: "SELECT count(*) FROM file_tags WHERE file_id = ? AND tag_id = ?", arguments: [row?.id, tagId])
        }
        #expect(tagCount == 1, "tag survived the move")
    }

    @Test func rescanDoesNotTreatAMissingFilesOldHashAsAMoveSource() async throws {
        // A file already marked 'missing' by a *prior* rescan is presumed really gone —
        // a brand new file that happens to share its content should get its own new
        // row, not silently resurrect the old one at the new path.
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let path = tempDir.appendingPathComponent("widget.stl")
        try "geometry".write(to: path, atomically: true, encoding: .utf8)

        let (_, rescan, enqueuer) = makeServices(db)
        var processed = 0
        try await rescan.run(root: library, rootURL: tempDir)
        try await drainNewIngestJobs(enqueuer: enqueuer, writer: db.writer, processedCount: &processed)
        let before = try await getFile(db, filename: "widget.stl")!

        try FileManager.default.removeItem(at: path)
        try await rescan.run(root: library, rootURL: tempDir)
        #expect(try await getFile(db, filename: "widget.stl")?.status == .missing)

        try "geometry".write(to: tempDir.appendingPathComponent("widget-again.stl"), atomically: true, encoding: .utf8)
        try await rescan.run(root: library, rootURL: tempDir)

        let again = try await getFile(db, filename: "widget-again.stl")
        #expect(again != nil)
        #expect(again?.id != before.id, "a genuinely new row, not a repoint")
        #expect(try await getFile(db, filename: "widget.stl")?.status == .missing, "old row still missing")
    }

    private func getSidecar(_ db: SQLiteSpoolDatabase, filename: String) async throws -> SidecarFile? {
        try await db.writer.read { conn in try SidecarFile.filter(Column("filename") == filename).fetchOne(conn) }
    }

    @Test func rescanMarksRemovedSidecarMissing() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let folder = tempDir.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("widget.stl"), atomically: true, encoding: .utf8)
        let sidecarPath = folder.appendingPathComponent("README.txt")
        try "readme".write(to: sidecarPath, atomically: true, encoding: .utf8)

        let (_, rescan, _) = makeServices(db)
        try await rescan.run(root: library, rootURL: tempDir)
        #expect(try await getSidecar(db, filename: "README.txt")?.status == .active)

        try FileManager.default.removeItem(at: sidecarPath)
        try await rescan.run(root: library, rootURL: tempDir)

        #expect(try await getSidecar(db, filename: "README.txt")?.status == .missing)
    }

    @Test func rescanRevivesMissingSidecarThatReappears() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let folder = tempDir.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("widget.stl"), atomically: true, encoding: .utf8)
        let sidecarPath = folder.appendingPathComponent("README.txt")
        try "readme".write(to: sidecarPath, atomically: true, encoding: .utf8)

        let (_, rescan, _) = makeServices(db)
        try await rescan.run(root: library, rootURL: tempDir)
        let beforeId = try await getSidecar(db, filename: "README.txt")?.id

        try FileManager.default.removeItem(at: sidecarPath)
        try await rescan.run(root: library, rootURL: tempDir)
        #expect(try await getSidecar(db, filename: "README.txt")?.status == .missing)

        try "readme again".write(to: sidecarPath, atomically: true, encoding: .utf8)
        try await rescan.run(root: library, rootURL: tempDir)

        let sidecar = try await getSidecar(db, filename: "README.txt")
        #expect(sidecar?.status == .active)
        #expect(sidecar?.id == beforeId, "same row revived, not a new one")

        let count = try await db.writer.read { conn in
            try Int.fetchOne(conn, sql: "SELECT count(*) FROM sidecar_files WHERE filename = 'README.txt'")
        }
        #expect(count == 1, "no duplicate row")
    }

    @Test func rescanUpdatesLastScannedAt() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let dropfolder = try await makeRoot(db, kind: .dropFolder)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (_, rescan, _) = makeServices(db)
        try await rescan.run(root: dropfolder, rootURL: tempDir)

        let lastScanned = try await db.writer.read { conn in
            try Date.fetchOne(conn, sql: "SELECT last_scanned_at FROM watched_roots WHERE id = ?", arguments: [dropfolder.id])
        }
        #expect(lastScanned != nil)
    }

    @Test func rescanSkipsUnreadableFileWithoutAbortingThePass() async throws {
        // Same regression class as backfill's equivalent fix: one unreadable file must
        // not block the rest of the pass. Standing in for the source app's real OSError
        // during hashing: a directory literally named "corrupted.stl" — `resourceValues`
        // succeeds (isDirectory == true), so it's silently skipped as a directory
        // instead of ever being treated as a model file, in contrast to a genuinely
        // unreadable regular file — a reasonably close, fully portable stand-in for
        // "this specific file can't be processed as a model right now" that doesn't
        // depend on injecting a real OS-level read failure.
        let db = try SQLiteSpoolDatabase(path: nil)
        let library = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("corrupted.stl"), withIntermediateDirectories: true
        )
        try "good".write(to: tempDir.appendingPathComponent("good.stl"), atomically: true, encoding: .utf8)

        let (_, rescan, _) = makeServices(db)
        try await rescan.run(root: library, rootURL: tempDir) // must not throw

        #expect(try await getFile(db, filename: "good.stl") != nil)
        #expect(try await getFile(db, filename: "corrupted.stl") == nil)
    }

    @Test func rescanRelocatesNewFileForARelocateToDropfolderRootJustLikeBackfill() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let dropfolder = try await makeRoot(db, kind: .dropFolder, hostPath: "/tmp/rescan-drop")
        let downloads = try await db.writer.write { conn in
            try WatchedRoot(
                hostPath: "/tmp/rescan-downloads", label: "Downloads", kind: .downloads,
                ingestMode: .relocateToDropfolder, bookmarkData: Data()
            ).inserted(conn)
        }
        let dropDir = try makeTempDir()
        let downloadsDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dropDir)
            try? FileManager.default.removeItem(at: downloadsDir)
        }
        try "solo".write(to: downloadsDir.appendingPathComponent("solo.stl"), atomically: true, encoding: .utf8)

        let (_, rescan, _) = makeServices(db)
        try await rescan.run(root: downloads, rootURL: downloadsDir, dropFolderRoot: (root: dropfolder, url: dropDir))

        #expect(FileManager.default.fileExists(atPath: dropDir.appendingPathComponent("solo.stl").path))
        #expect(!FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("solo.stl").path))
        let row = try await getFile(db, filename: "solo.stl")
        #expect(row?.watchedRootId == dropfolder.id)
    }
}
