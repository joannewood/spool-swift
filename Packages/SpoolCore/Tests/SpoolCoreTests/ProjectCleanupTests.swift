import Foundation
import Testing
@testable import SpoolCore

@Suite struct ProjectCleanupTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase, kind: RootKind = .dropFolder) async throws -> WatchedRoot {
        try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp/\(UUID().uuidString)", label: "x", kind: kind, bookmarkData: Data()).inserted(conn)
        }
    }

    private func makeFile(_ db: SQLiteSpoolDatabase, rootId: Int64, path: String) async throws -> Int64 {
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: rootId, path: path, filename: (path as NSString).lastPathComponent, ext: "stl", sizeBytes: 1)
                .inserted(conn)
        }
        return file.id!
    }

    private func makeProject(_ db: SQLiteSpoolDatabase, name: String, parentId: Int64? = nil, autoCreated: Bool) async throws -> Int64 {
        let project = try await db.writer.write { conn in
            try Project(
                name: name, parentProjectId: parentId,
                sourceFolderPath: autoCreated ? "/tmp/\(UUID().uuidString)" : nil
            ).inserted(conn)
        }
        return project.id!
    }

    private func link(_ db: SQLiteSpoolDatabase, projectId: Int64, fileId: Int64) async throws {
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'confirmed')",
                arguments: [projectId, fileId]
            )
        }
    }

    @Test func deleteIfEmptyAndAutoCreatedLeavesAManuallyCreatedProjectAlone() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let projectId = try await makeProject(db, name: "Kept", autoCreated: false)

        try await db.writer.write { conn in try ProjectCleanup.deleteIfEmptyAndAutoCreated(projectId: projectId, conn: conn) }

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: projectId) }
        #expect(refetched != nil, "a manually-created project must never be auto-deleted, even if empty")
    }

    @Test func deleteIfEmptyAndAutoCreatedLeavesAProjectWithAChildAlone() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let parentId = try await makeProject(db, name: "Parent", autoCreated: true)
        _ = try await makeProject(db, name: "Child", parentId: parentId, autoCreated: true)

        try await db.writer.write { conn in try ProjectCleanup.deleteIfEmptyAndAutoCreated(projectId: parentId, conn: conn) }

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: parentId) }
        #expect(refetched != nil, "an empty auto-created parent with a real child must survive — deleting it would orphan the child")
    }

    @Test func deleteIfEmptyAndAutoCreatedRemovesAChildlessFilelessAutoCreatedProject() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let projectId = try await makeProject(db, name: "Dead", autoCreated: true)

        try await db.writer.write { conn in try ProjectCleanup.deleteIfEmptyAndAutoCreated(projectId: projectId, conn: conn) }

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: projectId) }
        #expect(refetched == nil)
    }

    @Test func sweepCollapsesANestedChainOfNowEmptyAutoCreatedProjectsBottomUp() async throws {
        // Reproduces the real shape found live: a leftover auto-created parent and
        // child, both emptied by a since-removed watched root's cascade-deleted
        // files, still nested together — neither individually childless-and-empty
        // in a way a single non-repeating pass would fully clean up in one go if it
        // only checked the parent (it has a child) before the child (which had
        // already lost its files) was removed first.
        let db = try SQLiteSpoolDatabase(path: nil)
        let parentId = try await makeProject(db, name: "Belt Conveyor", autoCreated: true)
        let childId = try await makeProject(db, name: "Gnome", parentId: parentId, autoCreated: true)

        try await db.writer.write { conn in try ProjectCleanup.sweepEmptyAutoCreated(conn: conn) }

        let parent = try await db.writer.read { conn in try Project.fetchOne(conn, id: parentId) }
        let child = try await db.writer.read { conn in try Project.fetchOne(conn, id: childId) }
        #expect(parent == nil, "the parent must be swept up once its only child is gone, not left behind")
        #expect(child == nil)
    }

    @Test func sweepLeavesAProjectWithRealFilesAlone() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let projectId = try await makeProject(db, name: "Has Files", autoCreated: true)
        let fileId = try await makeFile(db, rootId: root.id!, path: "/tmp/has-files/model.stl")
        try await link(db, projectId: projectId, fileId: fileId)

        try await db.writer.write { conn in try ProjectCleanup.sweepEmptyAutoCreated(conn: conn) }

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: projectId) }
        #expect(refetched != nil)
    }

    @Test func sweepLeavesAManuallyCreatedEmptyProjectAlone() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let projectId = try await makeProject(db, name: "Manual", autoCreated: false)

        try await db.writer.write { conn in try ProjectCleanup.sweepEmptyAutoCreated(conn: conn) }

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: projectId) }
        #expect(refetched != nil)
    }
}
