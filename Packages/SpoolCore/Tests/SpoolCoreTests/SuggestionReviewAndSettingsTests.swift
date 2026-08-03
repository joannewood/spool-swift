import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct SuggestionReviewAndSettingsTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp/\(UUID().uuidString)", label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    private func makeFile(_ db: SQLiteSpoolDatabase, rootId: Int64, path: String) async throws -> Int64 {
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: rootId, path: path, filename: (path as NSString).lastPathComponent, ext: "stl", sizeBytes: 1)
                .inserted(conn)
        }
        return file.id!
    }

    @Test func confirmingARelationshipChangesOnlyThatRow() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let b = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let rel = try await db.writer.write { conn in
            try Relationship(fromFileId: a, toFileId: b, type: .duplicateOf).inserted(conn)
        }

        let service = SuggestionReviewService(writer: db.writer)
        #expect(try await service.suggestedRelationships().count == 1)

        try await service.confirmRelationship(id: rel.id!)
        #expect(try await service.suggestedRelationships().isEmpty)

        let refetched = try await db.writer.read { conn in try Relationship.fetchOne(conn, id: rel.id!) }
        #expect(refetched?.status == .confirmed)
    }

    @Test func removeRelationshipDeletesEvenAConfirmedRow() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let b = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let rel = try await db.writer.write { conn in
            try Relationship(fromFileId: a, toFileId: b, type: .variantOf, status: .confirmed).inserted(conn)
        }

        let service = SuggestionReviewService(writer: db.writer)
        try await service.removeRelationship(id: rel.id!)

        let refetched = try await db.writer.read { conn in try Relationship.fetchOne(conn, id: rel.id!) }
        #expect(refetched == nil, "unlike reject, remove leaves no tombstone row at all")
    }

    @Test func confirmRelationshipsOnlyConfirmsTheGivenSubset() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let b = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let c = try await makeFile(db, rootId: rootId, path: "/tmp/c.stl")
        let relAB = try await db.writer.write { conn in try Relationship(fromFileId: a, toFileId: b, type: .variantOf).inserted(conn) }
        let relAC = try await db.writer.write { conn in try Relationship(fromFileId: a, toFileId: c, type: .variantOf).inserted(conn) }

        let service = SuggestionReviewService(writer: db.writer)
        try await service.confirmRelationships(ids: [relAB.id!])

        #expect(try await db.writer.read { conn in try Relationship.fetchOne(conn, id: relAB.id!) }?.status == .confirmed)
        #expect(try await db.writer.read { conn in try Relationship.fetchOne(conn, id: relAC.id!) }?.status == .suggested)
    }

    @Test func confirmAllSuggestedRelationshipsConfirmsEveryOne() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let b = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let c = try await makeFile(db, rootId: rootId, path: "/tmp/c.stl")
        _ = try await db.writer.write { conn in try Relationship(fromFileId: a, toFileId: b, type: .variantOf).inserted(conn) }
        _ = try await db.writer.write { conn in try Relationship(fromFileId: a, toFileId: c, type: .variantOf).inserted(conn) }

        let service = SuggestionReviewService(writer: db.writer)
        let confirmedCount = try await service.confirmAllSuggestedRelationships()

        #expect(confirmedCount == 2)
        #expect(try await service.suggestedRelationships().isEmpty)
    }

    @Test func confirmProjectMembershipsOnlyConfirmsTheGivenPairs() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileA = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let fileB = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let project = try await db.writer.write { conn in try Project(name: "Kit").inserted(conn) }
        try await db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'suggested')", arguments: [project.id!, fileA])
            try conn.execute(sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'suggested')", arguments: [project.id!, fileB])
        }

        let service = SuggestionReviewService(writer: db.writer)
        try await service.confirmProjectMemberships([(projectId: project.id!, fileId: fileA)])

        let memberships = try await db.writer.read { conn in try ProjectFile.fetchAll(conn) }
        #expect(memberships.first(where: { $0.fileId == fileA })?.status == .confirmed)
        #expect(memberships.first(where: { $0.fileId == fileB })?.status == .suggested)
    }

    @Test func confirmAllSuggestedProjectMembershipsConfirmsEveryOne() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileA = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let fileB = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let project = try await db.writer.write { conn in try Project(name: "Kit").inserted(conn) }
        try await db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'suggested')", arguments: [project.id!, fileA])
            try conn.execute(sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'suggested')", arguments: [project.id!, fileB])
        }

        let service = SuggestionReviewService(writer: db.writer)
        let confirmedCount = try await service.confirmAllSuggestedProjectMemberships()

        #expect(confirmedCount == 2)
        #expect(try await service.suggestedProjectMemberships().isEmpty)
    }

    @Test func rejectingAProjectMembershipSuggestion() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let project = try await db.writer.write { conn in try Project(name: "Kit").inserted(conn) }
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'suggested')",
                arguments: [project.id!, fileId]
            )
        }

        let service = SuggestionReviewService(writer: db.writer)
        #expect(try await service.suggestedProjectMemberships().count == 1)

        try await service.rejectProjectMembership(projectId: project.id!, fileId: fileId)
        #expect(try await service.suggestedProjectMemberships().isEmpty)

        let refetched = try await db.writer.read { conn in
            try ProjectFile.filter(Column("project_id") == project.id!).filter(Column("file_id") == fileId).fetchOne(conn)
        }
        #expect(refetched?.status == .rejected)
    }

    @Test func appSettingsDefaultsAndUpdate() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = AppSettingsService(writer: db.writer)

        let initial = try await service.get()
        #expect(initial.rescanEnabled == true)
        #expect(initial.rescanIntervalSeconds == 300)

        try await service.updateRescan(enabled: false, intervalSeconds: 600)
        let updated = try await service.get()
        #expect(updated.rescanEnabled == false)
        #expect(updated.rescanIntervalSeconds == 600)
    }

    @Test func rescanIntervalIsFlooredAt30Seconds() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = AppSettingsService(writer: db.writer)

        try await service.updateRescan(enabled: true, intervalSeconds: 5)
        let settings = try await service.get()
        #expect(settings.rescanIntervalSeconds == 30, "an aggressive value must be floored, not turn the rescan loop into a tight poll")
    }

    @Test func autoAcceptArchivesToggle() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = AppSettingsService(writer: db.writer)

        try await service.updateAutoAcceptArchives(true)
        #expect(try await service.get().autoAcceptArchives == true)
    }
}
