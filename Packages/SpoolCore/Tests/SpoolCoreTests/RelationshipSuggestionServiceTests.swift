import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct RelationshipSuggestionServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp", label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    private func makeFile(
        _ db: SQLiteSpoolDatabase, rootId: Int64, filename: String, ext: String, hash: String
    ) async throws -> Int64 {
        let file = try await db.writer.write { conn in
            try SpoolFile(
                watchedRootId: rootId, path: "/tmp/\(filename)", filename: filename, ext: ext,
                sizeBytes: 1, contentHash: hash
            ).inserted(conn)
        }
        return file.id!
    }

    private func relationships(_ db: SQLiteSpoolDatabase) async throws -> [Relationship] {
        try await db.writer.read { conn in try Relationship.fetchAll(conn) }
    }

    @Test func identicalContentHashSuggestsDuplicateOf() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, filename: "widget.stl", ext: "stl", hash: "same-hash")
        let b = try await makeFile(db, rootId: rootId, filename: "widget_copy.stl", ext: "stl", hash: "same-hash")

        let service = RelationshipSuggestionService(writer: db.writer)
        try await service.suggestRelationships(forFileId: b)

        let rels = try await relationships(db)
        #expect(rels.count == 1)
        #expect(rels.first?.type == .duplicateOf)
        #expect(rels.first?.status == .suggested)
        #expect(Set([rels.first?.fromFileId, rels.first?.toFileId]) == Set([a, b]))
    }

    @Test func sameBasenameOneStepSuggestsDerivedFrom() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let step = try await makeFile(db, rootId: rootId, filename: "bracket.step", ext: "step", hash: "hash-a")
        let stl = try await makeFile(db, rootId: rootId, filename: "bracket.stl", ext: "stl", hash: "hash-b")

        let service = RelationshipSuggestionService(writer: db.writer)
        try await service.suggestRelationships(forFileId: stl)

        let rels = try await relationships(db)
        #expect(rels.count == 1)
        #expect(rels.first?.type == .derivedFrom)
        // The non-STEP file is "derived from" the STEP file: from=stl, to=step.
        #expect(rels.first?.fromFileId == stl)
        #expect(rels.first?.toFileId == step)
    }

    @Test func versionSuffixSuggestsNewVersionOfNewerToOlder() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let v1 = try await makeFile(db, rootId: rootId, filename: "handle_v1.stl", ext: "stl", hash: "hash-a")
        let v2 = try await makeFile(db, rootId: rootId, filename: "handle_v2.stl", ext: "stl", hash: "hash-b")

        let service = RelationshipSuggestionService(writer: db.writer)
        try await service.suggestRelationships(forFileId: v2)

        let rels = try await relationships(db)
        #expect(rels.count == 1)
        #expect(rels.first?.type == .newVersionOf)
        #expect(rels.first?.fromFileId == v2, "newer version is the 'from' side")
        #expect(rels.first?.toFileId == v1)
    }

    @Test func hyphenVersionSeparatorAlsoMatches() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let v1 = try await makeFile(db, rootId: rootId, filename: "handle-v1.stl", ext: "stl", hash: "hash-a")
        let v12 = try await makeFile(db, rootId: rootId, filename: "handle-v12.stl", ext: "stl", hash: "hash-b")

        let service = RelationshipSuggestionService(writer: db.writer)
        try await service.suggestRelationships(forFileId: v12)

        let rels = try await relationships(db)
        #expect(rels.count == 1)
        #expect(rels.first?.fromFileId == v12, "v12 > v1 numerically, not lexically")
        #expect(rels.first?.toFileId == v1)
    }

    @Test func unrelatedFilesGetNoSuggestion() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        _ = try await makeFile(db, rootId: rootId, filename: "cat.stl", ext: "stl", hash: "hash-a")
        let dog = try await makeFile(db, rootId: rootId, filename: "dog.stl", ext: "stl", hash: "hash-b")

        let service = RelationshipSuggestionService(writer: db.writer)
        try await service.suggestRelationships(forFileId: dog)

        let rels = try await relationships(db)
        #expect(rels.isEmpty)
    }

    @Test func rerunningDoesNotDuplicateOrOverwriteAManuallyConfirmedSuggestion() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, filename: "widget.stl", ext: "stl", hash: "same-hash")
        let b = try await makeFile(db, rootId: rootId, filename: "widget_copy.stl", ext: "stl", hash: "same-hash")

        let service = RelationshipSuggestionService(writer: db.writer)
        try await service.suggestRelationships(forFileId: b)

        // A user confirms the suggestion...
        try await db.writer.write { conn in
            try conn.execute(sql: "UPDATE relationships SET status = 'confirmed' WHERE from_file_id = ? OR to_file_id = ?", arguments: [b, b])
        }
        // ...and a later rescan re-running suggestion logic must not revert it.
        try await service.suggestRelationships(forFileId: a)

        let rels = try await relationships(db)
        #expect(rels.count == 1)
        #expect(rels.first?.status == .confirmed)
    }
}
