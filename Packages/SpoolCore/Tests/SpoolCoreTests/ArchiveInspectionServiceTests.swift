import Foundation
import GRDB
import Testing
import ZIPFoundation
@testable import SpoolCore

private actor RecordingEnqueuer: JobEnqueuer {
    private(set) var calls: [(zipFileId: Int64?, jobType: JobType)] = []
    func enqueue(fileId: Int64?, zipFileId: Int64?, jobType: JobType) async throws -> Job {
        calls.append((zipFileId, jobType))
        return Job(zipFileId: zipFileId, jobType: jobType)
    }
}

@Suite struct ArchiveInspectionServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp/\(UUID().uuidString)", label: "x", kind: .dropFolder, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    private func makeZip(withEntries entries: [(path: String, contents: String)]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveInspectionTests-\(UUID().uuidString).zip")
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            let data = Data(entry.contents.utf8)
            try archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
        return url
    }

    @Test func zipContainingARecognizedModelFileIsStagedAsSuggested() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let zipURL = try makeZip(withEntries: [("readme.txt", "hi"), ("model/widget.stl", "geometry")])
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let enqueuer = RecordingEnqueuer()
        let service = ArchiveInspectionService(writer: db.writer, enqueuer: enqueuer)
        try await service.inspect(path: zipURL.path, watchedRootId: rootId)

        let zips = try await db.writer.read { conn in try ZipFile.fetchAll(conn) }
        #expect(zips.count == 1)
        #expect(zips.first?.status == .suggested)
        #expect(await enqueuer.calls.isEmpty, "no auto-accept setting, so no job should fire yet")
    }

    @Test func zipWithNoRecognizedModelFileIsNeverTracked() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let zipURL = try makeZip(withEntries: [("readme.txt", "hi"), ("photo.jpg", "binary-ish")])
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let service = ArchiveInspectionService(writer: db.writer, enqueuer: RecordingEnqueuer())
        try await service.inspect(path: zipURL.path, watchedRootId: rootId)

        #expect(try await db.writer.read { conn in try ZipFile.fetchAll(conn) }.isEmpty)
    }

    @Test func autoAcceptImmediatelyConfirmsAndEnqueuesExtraction() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        try await AppSettingsService(writer: db.writer).updateAutoAcceptArchives(true)
        let zipURL = try makeZip(withEntries: [("widget.3mf", "geometry")])
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let enqueuer = RecordingEnqueuer()
        let service = ArchiveInspectionService(writer: db.writer, enqueuer: enqueuer)
        try await service.inspect(path: zipURL.path, watchedRootId: rootId)

        let zips = try await db.writer.read { conn in try ZipFile.fetchAll(conn) }
        #expect(zips.first?.status == .confirmed)
        let calls = await enqueuer.calls
        #expect(calls.count == 1)
        #expect(calls.first?.jobType == .extractZip)
    }

    @Test func sameContentAtSamePathIsNeverReStaged() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let zipURL = try makeZip(withEntries: [("widget.stl", "geometry")])
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let service = ArchiveInspectionService(writer: db.writer, enqueuer: RecordingEnqueuer())
        try await service.inspect(path: zipURL.path, watchedRootId: rootId)
        // Simulate a user rejecting it, then a later rescan re-inspecting the same file.
        try await db.writer.write { conn in try conn.execute(sql: "UPDATE zip_files SET status = 'rejected'") }
        try await service.inspect(path: zipURL.path, watchedRootId: rootId)

        let zips = try await db.writer.read { conn in try ZipFile.fetchAll(conn) }
        #expect(zips.count == 1, "a rejected archive at unchanged content must not be re-asked about")
        #expect(zips.first?.status == .rejected)
    }

    @Test func differentContentAtAReusedPathGetsAFreshSuggestedRow() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Archive-\(UUID().uuidString).zip").path

        let first = try makeZip(withEntries: [("widget.stl", "geometry-v1")])
        try FileManager.default.moveItem(atPath: first.path, toPath: path)
        let service = ArchiveInspectionService(writer: db.writer, enqueuer: RecordingEnqueuer())
        try await service.inspect(path: path, watchedRootId: rootId)
        try await db.writer.write { conn in try conn.execute(sql: "UPDATE zip_files SET status = 'rejected'") }

        // Same filename, genuinely different content (the "Archive.zip downloaded
        // again" case the source app's migration 011 fixed).
        try FileManager.default.removeItem(atPath: path)
        let second = try makeZip(withEntries: [("widget.stl", "totally-different-geometry-v2")])
        try FileManager.default.moveItem(atPath: second.path, toPath: path)
        try await service.inspect(path: path, watchedRootId: rootId)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let zips = try await db.writer.read { conn in try ZipFile.fetchAll(conn) }
        #expect(zips.count == 2)
        #expect(zips.contains { $0.status == .rejected })
        #expect(zips.contains { $0.status == .suggested })
    }

    @Test func malformedZipIsNeverTrackedRatherThanCrashing() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let badZipURL = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveInspectionTests-\(UUID().uuidString).zip")
        try Data("this is not a real zip file".utf8).write(to: badZipURL)
        defer { try? FileManager.default.removeItem(at: badZipURL) }

        let service = ArchiveInspectionService(writer: db.writer, enqueuer: RecordingEnqueuer())
        try await service.inspect(path: badZipURL.path, watchedRootId: rootId) // must not throw

        #expect(try await db.writer.read { conn in try ZipFile.fetchAll(conn) }.isEmpty)
    }

    @Test func sevenZipIsAlwaysTrackedAsUnsupportedFormat() async throws {
        // No native or pure-Swift .7z/.rar reader exists, and no in-sandbox way to
        // shell out to an external `unar`/`7z` either (confirmed live: App Sandbox
        // doesn't extend a security-scoped bookmark's file-read access to process-
        // execute rights) — so every .7z/.rar is tracked as unsupported unconditionally,
        // regardless of content, so the review UI can point the user at extracting it
        // manually instead of silently dropping it.
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let archiveURL = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveInspectionTests-\(UUID().uuidString).7z")
        try Data("not a real 7z file, but its content doesn't matter here".utf8).write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: archiveURL) }

        let service = ArchiveInspectionService(writer: db.writer, enqueuer: RecordingEnqueuer())
        try await service.inspect(path: archiveURL.path, watchedRootId: rootId)

        let zips = try await db.writer.read { conn in try ZipFile.fetchAll(conn) }
        #expect(zips.count == 1)
        #expect(zips.first?.status == .unsupportedFormat)
    }

    @Test func nonArchiveExtensionIsIgnored() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let service = ArchiveInspectionService(writer: db.writer, enqueuer: RecordingEnqueuer())
        try await service.inspect(path: "/tmp/not-an-archive.stl", watchedRootId: rootId)
        #expect(try await db.writer.read { conn in try ZipFile.fetchAll(conn) }.isEmpty)
    }
}
