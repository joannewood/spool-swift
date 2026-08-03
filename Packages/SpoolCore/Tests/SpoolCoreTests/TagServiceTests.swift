import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct TagServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(
                hostPath: "/tmp/\(UUID().uuidString)", label: "x", kind: .library, bookmarkData: Data()
            ).inserted(conn)
        }
        return root.id!
    }

    private func makeFile(_ db: SQLiteSpoolDatabase, rootId: Int64, path: String = "/tmp/a.stl") async throws -> Int64 {
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: rootId, path: path, filename: (path as NSString).lastPathComponent, ext: "stl", sizeBytes: 1)
                .inserted(conn)
        }
        return file.id!
    }

    @Test func addingATagCreatesItAndAttachesToTheFile() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId)
        let service = TagService(writer: db.writer)

        try await service.addTag(named: "PLA", toFileId: fileId)
        let tags = try await service.tags(forFileId: fileId)
        #expect(tags.map(\.name) == ["PLA"])
    }

    @Test func addingTheSameTagToTwoFilesReusesOneTagRow() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let b = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let service = TagService(writer: db.writer)

        try await service.addTag(named: "PLA", toFileId: a)
        try await service.addTag(named: "PLA", toFileId: b)

        let allTags = try await service.allTags()
        #expect(allTags.count == 1, "the same tag name must not create a second row")
    }

    @Test func addingTheSameTagTwiceToOneFileIsANoOp() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId)
        let service = TagService(writer: db.writer)

        try await service.addTag(named: "PLA", toFileId: fileId)
        try await service.addTag(named: "PLA", toFileId: fileId)

        let tags = try await service.tags(forFileId: fileId)
        #expect(tags.count == 1)
    }

    @Test func blankTagNameIsIgnored() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId)
        let service = TagService(writer: db.writer)

        let result = try await service.addTag(named: "   ", toFileId: fileId)
        #expect(result == nil)
        #expect(try await service.tags(forFileId: fileId).isEmpty)
    }

    @Test func removingATagDetachesButDoesNotDeleteTheSharedTagRow() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let b = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let service = TagService(writer: db.writer)

        let tag = try await service.addTag(named: "PLA", toFileId: a)!
        try await service.addTag(named: "PLA", toFileId: b)

        try await service.removeTag(tagId: tag.id!, fromFileId: a)

        #expect(try await service.tags(forFileId: a).isEmpty)
        #expect(try await service.tags(forFileId: b).map(\.name) == ["PLA"], "b's tag must be unaffected")
    }
}
