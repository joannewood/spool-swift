import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct FileServiceTests {
    private func makeFile(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp/\(UUID().uuidString)", label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: root.id!, path: "/tmp/a.stl", filename: "a.stl", ext: "stl", sizeBytes: 1).inserted(conn)
        }
        return file.id!
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRealFile(_ db: SQLiteSpoolDatabase, in dir: URL, name: String, kind: RootKind) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: dir.path, label: "x", kind: kind, bookmarkData: Data()).inserted(conn)
        }
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: root.id!, path: url.path, filename: name, ext: "stl", sizeBytes: 1).inserted(conn)
        }
        return file.id!
    }

    @Test func setDisplayNameTrimsAndPersists() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let fileId = try await makeFile(db)
        let service = FileService(writer: db.writer)

        try await service.setDisplayName(fileId: fileId, to: "  My Widget  ")

        let refetched = try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: fileId) }
        #expect(refetched?.displayName == "My Widget")
    }

    @Test func setDisplayNameBlankClearsTheOverride() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let fileId = try await makeFile(db)
        let service = FileService(writer: db.writer)
        try await service.setDisplayName(fileId: fileId, to: "Something")

        try await service.setDisplayName(fileId: fileId, to: "   ")

        let refetched = try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: fileId) }
        #expect(refetched?.displayName == nil)
    }

    @Test func deleteTrashesTheRealFileAndRemovesTheRow() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileId = try await makeRealFile(db, in: tempDir, name: "a.stl", kind: .dropFolder)
        let path = tempDir.appendingPathComponent("a.stl").path

        let service = FileService(writer: db.writer)
        try await service.delete(fileId: fileId)

        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: fileId) } == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func deleteFromLibraryRootIsBlocked() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let fileId = try await makeRealFile(db, in: tempDir, name: "a.stl", kind: .library)

        let service = FileService(writer: db.writer)
        await #expect(throws: FileService.DeletionError.self) {
            try await service.delete(fileId: fileId)
        }
        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: fileId) } != nil)
    }

    @Test func deleteFilesSkipsLibraryFilesButDeletesTheRest() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let dropDir = try makeTempDir()
        let libraryDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: dropDir)
            try? FileManager.default.removeItem(at: libraryDir)
        }
        let deletableId = try await makeRealFile(db, in: dropDir, name: "deletable.stl", kind: .dropFolder)
        let libraryId = try await makeRealFile(db, in: libraryDir, name: "protected.stl", kind: .library)

        let service = FileService(writer: db.writer)
        let result = try await service.deleteFiles(fileIds: [deletableId, libraryId])

        #expect(result.deletedCount == 1)
        #expect(result.skippedLibraryFilenames == ["protected.stl"])
        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: deletableId) } == nil)
        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: libraryId) } != nil)
    }
}
