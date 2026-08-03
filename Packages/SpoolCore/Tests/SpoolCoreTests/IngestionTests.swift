import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import SpoolCore

/// Records enqueue calls instead of actually running a JobQueue, so ingestion/backfill
/// tests assert dispatch decisions directly.
private actor RecordingEnqueuer: JobEnqueuer {
    private(set) var calls: [(fileId: Int64?, jobType: JobType)] = []

    func enqueue(fileId: Int64?, zipFileId: Int64?, jobType: JobType) async throws -> Job {
        calls.append((fileId, jobType))
        return Job(fileId: fileId, zipFileId: zipFileId, jobType: jobType)
    }
}

@Suite struct IngestionTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `FileManager.default.temporaryDirectory` is `/var/folders/...`, an alias of
        // the canonical `/private/var/folders/...` that `FileManager.enumerator`
        // actually returns — Foundation's own `resolvingSymlinksInPath()` deliberately
        // leaves `/var` (like `/tmp`, `/etc`) unresolved for legacy compatibility, so
        // only the raw POSIX `realpath()` actually collapses it. Needed here so a
        // test's own path constructions and whatever the enumerator later reports are
        // textually identical, matching how a real (already-canonical) security-scoped
        // root URL behaves.
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private func makeRoot(_ db: SQLiteSpoolDatabase, kind: RootKind = .dropFolder, hostPath: String = "/tmp/whatever") async throws -> WatchedRoot {
        let root = WatchedRoot(hostPath: hostPath, label: "Test", kind: kind, bookmarkData: Data())
        return try await db.writer.write { conn in try root.inserted(conn) }
    }

    @Test func ingestHashesFileAndEnqueuesRenderForSTL() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("cube.stl")
        try "not real geometry, just needs bytes to hash".write(to: fileURL, atomically: true, encoding: .utf8)

        let stub = SpoolFile(watchedRootId: root.id!, path: fileURL.path, filename: "cube.stl", ext: "stl", sizeBytes: 10)
        let inserted = try await db.writer.write { conn in try stub.inserted(conn) }

        let enqueuer = RecordingEnqueuer()
        let handler = IngestJobHandler(writer: db.writer, enqueuer: enqueuer)
        try await handler.handle(Job(fileId: inserted.id, jobType: .ingest))

        let updated = try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: inserted.id!) }
        #expect(updated?.contentHash != nil)
        #expect(updated?.contentHash?.count == 64) // hex SHA-256

        let calls = await enqueuer.calls
        #expect(calls.count == 1)
        #expect(calls.first?.jobType == .render)
        #expect(calls.first?.fileId == inserted.id)
    }

    @Test func ingestDispatchesStepFilesToSlowLane() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("bracket.step")
        try "STEP-ish content".write(to: fileURL, atomically: true, encoding: .utf8)

        let stub = SpoolFile(watchedRootId: root.id!, path: fileURL.path, filename: "bracket.step", ext: "step", sizeBytes: 10)
        let inserted = try await db.writer.write { conn in try stub.inserted(conn) }

        let enqueuer = RecordingEnqueuer()
        try await IngestJobHandler(writer: db.writer, enqueuer: enqueuer).handle(Job(fileId: inserted.id, jobType: .ingest))

        let calls = await enqueuer.calls
        #expect(calls.first?.jobType == .renderStep)
    }

    @Test func ingestDispatchesObjSvgAndGcodeToTheFastRenderLane() async throws {
        // .obj/.svg/.gcode are all just other MESH/SVG/GCODE_EXTENSIONS entries — no CAD
        // tessellation, same fast lane as .stl/.3mf.
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let enqueuer = RecordingEnqueuer()

        for (filename, ext) in [("widget.obj", "obj"), ("logo.svg", "svg"), ("part.gcode", "gcode")] {
            let fileURL = tempDir.appendingPathComponent(filename)
            try "content".write(to: fileURL, atomically: true, encoding: .utf8)
            let stub = SpoolFile(watchedRootId: root.id!, path: fileURL.path, filename: filename, ext: ext, sizeBytes: 7)
            let inserted = try await db.writer.write { conn in try stub.inserted(conn) }
            try await IngestJobHandler(writer: db.writer, enqueuer: enqueuer).handle(Job(fileId: inserted.id, jobType: .ingest))
        }

        let calls = await enqueuer.calls
        #expect(calls.filter { $0.jobType == .render }.count == 3)
    }

    @Test func ingestMarksScadUnsupportedWithNoRenderJob() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileURL = tempDir.appendingPathComponent("widget.scad")
        try "module widget() {}".write(to: fileURL, atomically: true, encoding: .utf8)

        let stub = SpoolFile(watchedRootId: root.id!, path: fileURL.path, filename: "widget.scad", ext: "scad", sizeBytes: 10)
        let inserted = try await db.writer.write { conn in try stub.inserted(conn) }

        let enqueuer = RecordingEnqueuer()
        try await IngestJobHandler(writer: db.writer, enqueuer: enqueuer).handle(Job(fileId: inserted.id, jobType: .ingest))

        let updated = try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: inserted.id!) }
        #expect(updated?.renderStatus == .unsupported)
        let calls = await enqueuer.calls
        #expect(calls.isEmpty)
    }

    @Test func backfillStagesOnlyNewRecognizedFilesAndSkipsJunk() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "a".write(to: tempDir.appendingPathComponent("model.stl"), atomically: true, encoding: .utf8)
        try "b".write(to: tempDir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: tempDir.appendingPathComponent(".DS_Store"), atomically: true, encoding: .utf8)
        try "d".write(to: tempDir.appendingPathComponent("._AppleDouble.stl"), atomically: true, encoding: .utf8)

        let enqueuer = RecordingEnqueuer()
        let backfill = BackfillService(writer: db.writer, enqueuer: enqueuer)
        let stagedCount = try await backfill.run(root: root, rootURL: tempDir)

        #expect(stagedCount == 1)
        let files = try await db.writer.read { conn in try SpoolFile.fetchAll(conn) }
        #expect(files.count == 1)
        #expect(files.first?.filename == "model.stl")

        // Second pass is a no-op — already-known paths aren't re-staged.
        let secondPass = try await backfill.run(root: root, rootURL: tempDir)
        #expect(secondPass == 0)
    }

    @Test func stageIfNewHandlesTheLiveWatchSingleFileCase() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let newFile = tempDir.appendingPathComponent("live.stl")
        try "x".write(to: newFile, atomically: true, encoding: .utf8)

        let enqueuer = RecordingEnqueuer()
        let backfill = BackfillService(writer: db.writer, enqueuer: enqueuer)

        let staged = try await backfill.stageIfNew(path: newFile.path, root: root, rootURL: tempDir)
        #expect(staged == true)
        let calls = await enqueuer.calls
        #expect(calls.count == 1)
        #expect(calls.first?.jobType == .ingest)

        // Calling again for the same path is a no-op — already known.
        let stagedAgain = try await backfill.stageIfNew(path: newFile.path, root: root, rootURL: tempDir)
        #expect(stagedAgain == false)
        #expect(await enqueuer.calls.count == 1)

        // Junk and non-model files are ignored outright.
        let junkFile = tempDir.appendingPathComponent(".DS_Store")
        try "y".write(to: junkFile, atomically: true, encoding: .utf8)
        #expect(try await backfill.stageIfNew(path: junkFile.path, root: root, rootURL: tempDir) == false)
    }

    @Test func backfillWalkAlsoDiscoversArchivesInTheSamePass() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try "a".write(to: tempDir.appendingPathComponent("model.stl"), atomically: true, encoding: .utf8)
        let zipURL = tempDir.appendingPathComponent("Kit.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let data = Data("geometry".utf8)
        try archive.addEntry(with: "widget.3mf", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }

        let enqueuer = RecordingEnqueuer()
        let backfill = BackfillService(writer: db.writer, enqueuer: enqueuer)
        let staged = try await backfill.run(root: root, rootURL: tempDir)

        #expect(staged == 1, "only the model file counts toward the staged-file total")
        let zips = try await db.writer.read { conn in try ZipFile.fetchAll(conn) }
        #expect(zips.count == 1)
        #expect(zips.first?.filename == "Kit.zip")
        #expect(zips.first?.status == .suggested)
    }

    @Test func backfillSkipsAFileThatFailsToStageWithoutAbortingTheWholeWalk() async throws {
        // Regression coverage for a real incident in the source app: a handful of files
        // out of a ~2800-file bulk move transiently raised OSError when hashed, and
        // since run_backfill had no per-file try/except, hitting one bad file crashed
        // the whole backfill walk — under auto-restart, the worker just retried the
        // entire backfill from scratch and hit the same file again, forever.
        //
        // Standing in for that real OSError: pre-seed a `files` row under an UNRELATED
        // root at the exact path this walk is about to stage — `files.path` is globally
        // unique, so the walk's own insert attempt fails with a genuine DB conflict.
        // The property under test is the same either way: one per-file staging failure
        // must never abort the rest of the walk.
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let otherRoot = try await makeRoot(db, kind: .library, hostPath: "/tmp/other-root")
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let badURL = tempDir.appendingPathComponent("corrupted.stl")
        try "bad".write(to: badURL, atomically: true, encoding: .utf8)
        try "good".write(to: tempDir.appendingPathComponent("good.stl"), atomically: true, encoding: .utf8)

        _ = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: otherRoot.id!, path: badURL.path, filename: "corrupted.stl", ext: "stl", sizeBytes: 1)
                .inserted(conn)
        }

        let enqueuer = RecordingEnqueuer()
        let backfill = BackfillService(writer: db.writer, enqueuer: enqueuer)
        let staged = try await backfill.run(root: root, rootURL: tempDir) // must not throw

        #expect(staged == 1)
        let allFiles = try await db.writer.read { conn in try SpoolFile.fetchAll(conn) }
        let filenames = allFiles.filter { $0.watchedRootId == root.id }.map(\.filename)
        #expect(filenames == ["good.stl"]) // corrupted.stl skipped, good.stl still indexed
    }

    @Test func backfillRelocatesWholeFolderForRelocateToDropfolderRoot() async throws {
        // The whole Kit/ folder moves as a unit on the very first file processed in it
        // (directory-enumeration order isn't guaranteed to match creation order) — but
        // within that SAME backfill pass, only that first file actually gets staged:
        // its sibling's original path is gone by the time the loop reaches it (already
        // carried away by the folder move), so relocateFileOrFolder correctly reports
        // "nothing to do" for it rather than erroring. A second pass (of the drop
        // folder itself, now index_in_place) picks up the straggler + its sidecar.
        let db = try SQLiteSpoolDatabase(path: nil)
        let dropfolder = try await makeRoot(db, kind: .dropFolder)
        let downloads = try await db.writer.write { conn in
            try WatchedRoot(
                hostPath: "/tmp/downloads", label: "Downloads", kind: .downloads,
                ingestMode: .relocateToDropfolder, bookmarkData: Data()
            ).inserted(conn)
        }

        let dropDir = try makeTempDir()
        let downloadsDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dropDir)
            try? FileManager.default.removeItem(at: downloadsDir)
        }

        let kitDir = downloadsDir.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: kitDir, withIntermediateDirectories: true)
        try "a".write(to: kitDir.appendingPathComponent("part_a.stl"), atomically: true, encoding: .utf8)
        try "b".write(to: kitDir.appendingPathComponent("part_b.stl"), atomically: true, encoding: .utf8)
        try "readme".write(to: kitDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let enqueuer = RecordingEnqueuer()
        let backfill = BackfillService(writer: db.writer, enqueuer: enqueuer)
        let dropFolderRoot = (root: dropfolder, url: dropDir)
        _ = try await backfill.run(root: downloads, rootURL: downloadsDir, dropFolderRoot: dropFolderRoot)

        let relocatedKit = dropDir.appendingPathComponent("Kit")
        #expect(FileManager.default.fileExists(atPath: relocatedKit.path))
        #expect(FileManager.default.fileExists(atPath: relocatedKit.appendingPathComponent("part_a.stl").path))
        #expect(FileManager.default.fileExists(atPath: relocatedKit.appendingPathComponent("part_b.stl").path))
        #expect(FileManager.default.fileExists(atPath: relocatedKit.appendingPathComponent("README.txt").path))
        #expect(!FileManager.default.fileExists(atPath: kitDir.path), "moved, not copied")

        let files = try await db.writer.read { conn in try SpoolFile.fetchAll(conn) }
        #expect(files.count == 1, "only one of the two siblings got indexed in this same pass")
        #expect(["part_a.stl", "part_b.stl"].contains(files[0].filename))
        #expect(files[0].watchedRootId == dropfolder.id, "landed under the drop folder's root id")

        _ = try await backfill.run(root: dropfolder, rootURL: dropDir)
        let filesAfter = try await db.writer.read { conn in try SpoolFile.fetchAll(conn) }.map(\.filename).sorted()
        #expect(filesAfter == ["part_a.stl", "part_b.stl"])
        let sidecarsAfter = try await db.writer.read { conn in try SidecarFile.fetchAll(conn) }.map(\.filename)
        #expect(sidecarsAfter == ["README.txt"])
    }

    @Test func backfillNeverIndexesSidecarsAtTheirOriginalPathForARelocateToDropfolderRoot() async throws {
        // A relocate-mode root's sidecars must never be staged at their original
        // (pre-relocate) location — they either move with their folder or are
        // discovered at their new home once that folder shows up in the drop
        // folder's own walk. Staging them at the original path here would leave a
        // sidecar_files row pointing at a path that then gets moved out from under it.
        let db = try SQLiteSpoolDatabase(path: nil)
        let dropfolder = try await makeRoot(db, kind: .dropFolder)
        let downloads = try await db.writer.write { conn in
            try WatchedRoot(
                hostPath: "/tmp/downloads2", label: "Downloads", kind: .downloads,
                ingestMode: .relocateToDropfolder, bookmarkData: Data()
            ).inserted(conn)
        }
        let dropDir = try makeTempDir()
        let downloadsDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dropDir)
            try? FileManager.default.removeItem(at: downloadsDir)
        }

        // A file sitting directly at the root level (no meaningful parent folder) is
        // relocated alone, not as a whole-folder move — no sidecar involved at all here.
        try "solo".write(to: downloadsDir.appendingPathComponent("solo.stl"), atomically: true, encoding: .utf8)

        let enqueuer = RecordingEnqueuer()
        let backfill = BackfillService(writer: db.writer, enqueuer: enqueuer)
        _ = try await backfill.run(
            root: downloads, rootURL: downloadsDir, dropFolderRoot: (root: dropfolder, url: dropDir)
        )

        #expect(FileManager.default.fileExists(atPath: dropDir.appendingPathComponent("solo.stl").path))
        #expect(!FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("solo.stl").path))
        let files = try await db.writer.read { conn in try SpoolFile.fetchAll(conn) }
        #expect(files.count == 1)
        #expect(files.first?.watchedRootId == dropfolder.id)
    }
}
