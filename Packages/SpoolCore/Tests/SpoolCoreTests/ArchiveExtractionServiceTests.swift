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

@Suite struct ArchiveExtractionServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase, kind: RootKind, hostPath: String, ingestMode: RootIngestMode = .indexInPlace) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: hostPath, label: "x", kind: kind, ingestMode: ingestMode, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    private func makeZipFile(withEntries entries: [(path: String, contents: String)], at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            let data = Data(entry.contents.utf8)
            try archive.addEntry(with: entry.path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<Int(position) + size)
            }
        }
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveExtractionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func extractsAZipDeletesTheOriginalAndRemovesTheDBRow() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let rootId = try await makeRoot(db, kind: .dropFolder, hostPath: tempDir.path)

        let zipURL = tempDir.appendingPathComponent("Kit.zip")
        try makeZipFile(withEntries: [("widget.stl", "geometry")], at: zipURL)
        let zip = try await db.writer.write { conn in
            try ZipFile(watchedRootId: rootId, path: zipURL.path, filename: "Kit.zip", sizeBytes: 1, status: .confirmed, contentHash: "h").inserted(conn)
        }

        let service = ArchiveExtractionService(writer: db.writer)
        try await service.extract(zipFileId: zip.id!)

        #expect(!FileManager.default.fileExists(atPath: zipURL.path), "the original archive must be deleted")
        let extractedFile = tempDir.appendingPathComponent("Kit/widget.stl")
        #expect(FileManager.default.fileExists(atPath: extractedFile.path))
        #expect(try await db.writer.read { conn in try ZipFile.fetchOne(conn, id: zip.id!) } == nil)
    }

    @Test func relocatesExtractedFolderIntoTheDropFolderForDownloadsRoots() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let downloadsDir = try makeTempDir()
        let dropFolderDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: downloadsDir)
            try? FileManager.default.removeItem(at: dropFolderDir)
        }
        _ = try await makeRoot(db, kind: .dropFolder, hostPath: dropFolderDir.path)
        let downloadsRootId = try await makeRoot(db, kind: .downloads, hostPath: downloadsDir.path, ingestMode: .relocateToDropfolder)

        let zipURL = downloadsDir.appendingPathComponent("Kit.zip")
        try makeZipFile(withEntries: [("widget.stl", "geometry")], at: zipURL)
        let zip = try await db.writer.write { conn in
            try ZipFile(watchedRootId: downloadsRootId, path: zipURL.path, filename: "Kit.zip", sizeBytes: 1, status: .confirmed, contentHash: "h").inserted(conn)
        }

        let service = ArchiveExtractionService(writer: db.writer)
        try await service.extract(zipFileId: zip.id!)

        #expect(!FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent("Kit").path), "must not stay in Downloads")
        #expect(FileManager.default.fileExists(atPath: dropFolderDir.appendingPathComponent("Kit/widget.stl").path))
    }

    @Test func extractingIntoALibraryRootFailsLoudlyAndKeepsTheArchive() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let rootId = try await makeRoot(db, kind: .library, hostPath: tempDir.path)

        let zipURL = tempDir.appendingPathComponent("Kit.zip")
        try makeZipFile(withEntries: [("widget.stl", "geometry")], at: zipURL)
        let zip = try await db.writer.write { conn in
            try ZipFile(watchedRootId: rootId, path: zipURL.path, filename: "Kit.zip", sizeBytes: 1, status: .confirmed, contentHash: "h").inserted(conn)
        }

        let service = ArchiveExtractionService(writer: db.writer)
        await #expect(throws: ArchiveExtractionService.ExtractionError.self) {
            try await service.extract(zipFileId: zip.id!)
        }

        #expect(FileManager.default.fileExists(atPath: zipURL.path), "the archive must be untouched")
        let stored = try await db.writer.read { conn in try ZipFile.fetchOne(conn, id: zip.id!) }
        #expect(stored?.error != nil, "the failure must surface via zip_files.error")
    }

    @Test func reviewServiceConfirmEnqueuesExtraction() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, kind: .dropFolder, hostPath: "/tmp")
        let zip = try await db.writer.write { conn in
            try ZipFile(watchedRootId: rootId, path: "/tmp/a.zip", filename: "a.zip", sizeBytes: 1, status: .suggested, contentHash: "h").inserted(conn)
        }

        let enqueuer = RecordingEnqueuer()
        let review = ArchiveReviewService(writer: db.writer, enqueuer: enqueuer)
        try await review.confirm(zipFileId: zip.id!)

        let stored = try await db.writer.read { conn in try ZipFile.fetchOne(conn, id: zip.id!) }
        #expect(stored?.status == .confirmed)
        let calls = await enqueuer.calls
        #expect(calls.count == 1)
        #expect(calls.first?.jobType == .extractZip)
    }

    @Test func reviewServiceRejectAndUnreject() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, kind: .dropFolder, hostPath: "/tmp")
        let zip = try await db.writer.write { conn in
            try ZipFile(watchedRootId: rootId, path: "/tmp/a.zip", filename: "a.zip", sizeBytes: 1, status: .suggested, contentHash: "h").inserted(conn)
        }

        let review = ArchiveReviewService(writer: db.writer, enqueuer: RecordingEnqueuer())
        try await review.reject(zipFileId: zip.id!)
        #expect(try await review.rejectedArchives().map(\.id) == [zip.id])
        #expect(try await review.pendingArchives().isEmpty)

        try await review.unreject(zipFileId: zip.id!)
        #expect(try await review.pendingArchives().map(\.id) == [zip.id])
        #expect(try await review.rejectedArchives().isEmpty)
    }

    @Test func confirmSelectedOnlyExtractsTheGivenSubset() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, kind: .dropFolder, hostPath: "/tmp")
        let a = try await db.writer.write { conn in
            try ZipFile(watchedRootId: rootId, path: "/tmp/a.zip", filename: "a.zip", sizeBytes: 1, status: .suggested, contentHash: "a").inserted(conn)
        }
        let b = try await db.writer.write { conn in
            try ZipFile(watchedRootId: rootId, path: "/tmp/b.zip", filename: "b.zip", sizeBytes: 1, status: .suggested, contentHash: "b").inserted(conn)
        }

        let review = ArchiveReviewService(writer: db.writer, enqueuer: RecordingEnqueuer())
        try await review.confirm(zipFileIds: [a.id!])

        #expect(try await db.writer.read { conn in try ZipFile.fetchOne(conn, id: a.id!) }?.status == .confirmed)
        #expect(try await db.writer.read { conn in try ZipFile.fetchOne(conn, id: b.id!) }?.status == .suggested)
    }

    @Test func confirmAllExtractsEveryPendingArchive() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, kind: .dropFolder, hostPath: "/tmp")
        _ = try await db.writer.write { conn in
            try ZipFile(watchedRootId: rootId, path: "/tmp/a.zip", filename: "a.zip", sizeBytes: 1, status: .suggested, contentHash: "a").inserted(conn)
        }
        _ = try await db.writer.write { conn in
            try ZipFile(watchedRootId: rootId, path: "/tmp/b.zip", filename: "b.zip", sizeBytes: 1, status: .suggested, contentHash: "b").inserted(conn)
        }

        let enqueuer = RecordingEnqueuer()
        let review = ArchiveReviewService(writer: db.writer, enqueuer: enqueuer)
        let confirmedCount = try await review.confirmAll()

        #expect(confirmedCount == 2)
        #expect(try await review.pendingArchives().isEmpty)
        #expect(await enqueuer.calls.count == 2)
    }
}
