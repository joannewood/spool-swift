import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct DuplicateServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase, kind: RootKind = .dropFolder) async throws -> WatchedRoot {
        try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp/\(UUID().uuidString)", label: "x", kind: kind, bookmarkData: Data()).inserted(conn)
        }
    }

    private func makeFile(
        _ db: SQLiteSpoolDatabase, rootId: Int64, path: String, hash: String?, firstSeenAt: Date = Date()
    ) async throws -> Int64 {
        let file = try await db.writer.write { conn in
            try SpoolFile(
                watchedRootId: rootId, path: path, filename: (path as NSString).lastPathComponent, ext: "stl",
                sizeBytes: 1, contentHash: hash, firstSeenAt: firstSeenAt, lastSeenAt: firstSeenAt
            ).inserted(conn)
        }
        return file.id!
    }

    @Test func groupsFilesWithIdenticalHashOldestFirst() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let older = try await makeFile(db, rootId: root.id!, path: "/tmp/older.stl", hash: "dup", firstSeenAt: Date(timeIntervalSince1970: 1))
        let newer = try await makeFile(db, rootId: root.id!, path: "/tmp/newer.stl", hash: "dup", firstSeenAt: Date(timeIntervalSince1970: 2))
        _ = try await makeFile(db, rootId: root.id!, path: "/tmp/unique.stl", hash: "unique")

        let service = DuplicateService(writer: db.writer)
        let groups = try await service.listDuplicateGroups()

        #expect(groups.count == 1)
        #expect(groups.first?.files.map(\.id) == [older, newer], "oldest first")
    }

    @Test func filesWithNilHashAreNeverGroupedTogether() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        _ = try await makeFile(db, rootId: root.id!, path: "/tmp/a.stl", hash: nil)
        _ = try await makeFile(db, rootId: root.id!, path: "/tmp/b.stl", hash: nil)

        let service = DuplicateService(writer: db.writer)
        #expect(try await service.listDuplicateGroups().isEmpty)
    }

    @Test func deletingADuplicateRemovesTheDBRowForARealDropFolderFile() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db, kind: .dropFolder)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let filePath = tempDir.appendingPathComponent("dup.stl")
        try "x".write(to: filePath, atomically: true, encoding: .utf8)

        let fileId = try await makeFile(db, rootId: root.id!, path: filePath.path, hash: "dup")

        let service = DuplicateService(writer: db.writer)
        try await service.deleteDuplicate(fileId: fileId)

        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: fileId) } == nil)
        #expect(!FileManager.default.fileExists(atPath: filePath.path), "the real file must be trashed, not just untracked")
    }

    @Test func deletingFromTheLibraryRootIsBlocked() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db, kind: .library)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let filePath = tempDir.appendingPathComponent("protected.stl")
        try "x".write(to: filePath, atomically: true, encoding: .utf8)

        let fileId = try await makeFile(db, rootId: root.id!, path: filePath.path, hash: "dup")

        let service = DuplicateService(writer: db.writer)
        await #expect(throws: DuplicateService.DeletionError.self) {
            try await service.deleteDuplicate(fileId: fileId)
        }

        #expect(FileManager.default.fileExists(atPath: filePath.path), "the Library file must be untouched")
        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: fileId) } != nil, "the DB row must survive a blocked delete")
    }

    @Test func deletingADuplicateCleansUpTheNowEmptyAutoCreatedProject() async throws {
        // A deleted file is often the sole member of an auto-created project for what
        // turned out to be a duplicate download's own folder — confirmed live in the
        // source app as the cause of 349 real orphaned empty projects before this fix.
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db, kind: .dropFolder)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let filePath = tempDir.appendingPathComponent("dup.stl")
        try "x".write(to: filePath, atomically: true, encoding: .utf8)
        let fileId = try await makeFile(db, rootId: root.id!, path: filePath.path, hash: "dup")

        let autoProject = try await db.writer.write { conn in
            try Project(name: "Kit", sourceFolderPath: tempDir.path).inserted(conn)
        }
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'confirmed')",
                arguments: [autoProject.id!, fileId]
            )
        }

        let service = DuplicateService(writer: db.writer)
        try await service.deleteDuplicate(fileId: fileId)

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: autoProject.id!) }
        #expect(refetched == nil, "an auto-created project left with zero files is dead weight")
    }

    private func makeRealFile(in dir: URL, name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func deleteAllDuplicatesKeepsTheOldestWhenNoLibraryCopyExists() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db, kind: .dropFolder)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let olderPath = try makeRealFile(in: tempDir, name: "older.stl")
        let newerPath = try makeRealFile(in: tempDir, name: "newer.stl")
        let olderId = try await makeFile(db, rootId: root.id!, path: olderPath.path, hash: "dup", firstSeenAt: Date(timeIntervalSince1970: 1))
        let newerId = try await makeFile(db, rootId: root.id!, path: newerPath.path, hash: "dup", firstSeenAt: Date(timeIntervalSince1970: 2))

        let service = DuplicateService(writer: db.writer)
        let deletedCount = try await service.deleteAllDuplicates()

        #expect(deletedCount == 1)
        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: olderId) } != nil, "the oldest copy survives")
        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: newerId) } == nil)
    }

    @Test func deleteAllDuplicatesKeepsTheLibraryCopyRegardlessOfAge() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let dropRoot = try await makeRoot(db, kind: .dropFolder)
        let libraryRoot = try await makeRoot(db, kind: .library)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // The drop-folder copy is older, but the Library copy must still win — it's
        // the one copy Spool can never delete, so it's a forced keeper regardless.
        let olderDropPath = try makeRealFile(in: tempDir, name: "older-drop.stl")
        let libraryPath = try makeRealFile(in: tempDir, name: "library.stl")
        let olderDropId = try await makeFile(db, rootId: dropRoot.id!, path: olderDropPath.path, hash: "dup", firstSeenAt: Date(timeIntervalSince1970: 1))
        let libraryId = try await makeFile(db, rootId: libraryRoot.id!, path: libraryPath.path, hash: "dup", firstSeenAt: Date(timeIntervalSince1970: 2))

        let service = DuplicateService(writer: db.writer)
        let deletedCount = try await service.deleteAllDuplicates()

        #expect(deletedCount == 1)
        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: libraryId) } != nil, "the Library copy survives")
        #expect(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: olderDropId) } == nil)
    }

    @Test func deleteAllDuplicatesTouchesNothingWhenEveryCopyIsInLibrary() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let libraryRoot = try await makeRoot(db, kind: .library)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("DuplicateServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pathA = try makeRealFile(in: tempDir, name: "a.stl")
        let pathB = try makeRealFile(in: tempDir, name: "b.stl")
        _ = try await makeFile(db, rootId: libraryRoot.id!, path: pathA.path, hash: "dup")
        _ = try await makeFile(db, rootId: libraryRoot.id!, path: pathB.path, hash: "dup")

        let service = DuplicateService(writer: db.writer)
        let deletedCount = try await service.deleteAllDuplicates()

        #expect(deletedCount == 0, "nothing here is touchable — every copy is in the read-only Library root")
    }
}
