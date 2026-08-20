import Foundation
import Testing
@testable import SpoolCore

@Suite struct WatchedRootRepositoryTests {
    @Test func updateAppliesIngestModeForLibraryKind() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let repo = WatchedRootRepository(writer: db.writer)
        let root = try await repo.add(
            WatchedRoot(hostPath: "/tmp/lib", label: "Old Name", kind: .library, bookmarkData: Data())
        )

        try await repo.update(id: root.id!, label: "New Name", ingestMode: .relocateToDropfolder, active: false)

        let updated = try await repo.fetchAll().first { $0.id == root.id }
        #expect(updated?.label == "New Name")
        #expect(updated?.ingestMode == .relocateToDropfolder)
        #expect(updated?.active == false)
    }

    @Test func updateIgnoresIngestModeForDropFolderKind() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let repo = WatchedRootRepository(writer: db.writer)
        let root = try await repo.add(
            WatchedRoot(hostPath: "/tmp/drop", label: "Drop", kind: .dropFolder, ingestMode: .indexInPlace, bookmarkData: Data())
        )

        try await repo.update(id: root.id!, label: "Drop", ingestMode: .relocateToDropfolder, active: true)

        let updated = try await repo.fetchAll().first { $0.id == root.id }
        #expect(updated?.ingestMode == .indexInPlace, "a drop folder's ingest mode is fixed by its role")
    }

    @Test func updateIgnoresIngestModeForDownloadsKind() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let repo = WatchedRootRepository(writer: db.writer)
        let root = try await repo.add(
            WatchedRoot(
                hostPath: "/tmp/downloads", label: "Downloads", kind: .downloads,
                ingestMode: .relocateToDropfolder, bookmarkData: Data()
            )
        )

        try await repo.update(id: root.id!, label: "Downloads", ingestMode: .indexInPlace, active: true)

        let updated = try await repo.fetchAll().first { $0.id == root.id }
        #expect(
            updated?.ingestMode == .relocateToDropfolder,
            "flipping this to index_in_place would silently disable the one thing a downloads root exists to do"
        )
    }

    @Test func updateAlwaysUpdatesLabelAndActive() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let repo = WatchedRootRepository(writer: db.writer)
        let root = try await repo.add(
            WatchedRoot(hostPath: "/tmp/downloads2", label: "Old", kind: .downloads, ingestMode: .relocateToDropfolder, bookmarkData: Data())
        )

        try await repo.update(id: root.id!, label: "Renamed", ingestMode: .indexInPlace, active: false)

        let updated = try await repo.fetchAll().first { $0.id == root.id }
        #expect(updated?.label == "Renamed")
        #expect(updated?.active == false)
    }

    /// Reproduces a real orphaned-project bug found live: removing a root cascades
    /// its files away at the SQLite FK level (`ON DELETE CASCADE`), bypassing every
    /// per-file `ProjectCleanup` call `FileService`/`ProjectService` normally trigger
    /// — so an auto-created project (even a nested parent/child pair) that root's
    /// files were the only members of used to survive as a dead, empty shell.
    @Test func removeSweepsUpAnAutoCreatedProjectTreeItEmptiedViaCascade() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let repo = WatchedRootRepository(writer: db.writer)
        let root = try await repo.add(
            WatchedRoot(hostPath: "/tmp/\(UUID().uuidString)", label: "x", kind: .dropFolder, bookmarkData: Data())
        )
        let parent = try await db.writer.write { conn in
            try Project(name: "Parent", sourceFolderPath: "/tmp/parent-\(UUID().uuidString)").inserted(conn)
        }
        let child = try await db.writer.write { conn in
            try Project(name: "Child", parentProjectId: parent.id, sourceFolderPath: "/tmp/child-\(UUID().uuidString)").inserted(conn)
        }
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: root.id!, path: "/tmp/child/model.stl", filename: "model.stl", ext: "stl", sizeBytes: 1)
                .inserted(conn)
        }
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'confirmed')",
                arguments: [child.id!, file.id!]
            )
        }

        try await repo.remove(id: root.id!)

        let parentAfter = try await db.writer.read { conn in try Project.fetchOne(conn, id: parent.id!) }
        let childAfter = try await db.writer.read { conn in try Project.fetchOne(conn, id: child.id!) }
        #expect(parentAfter == nil, "left behind exactly like the real leftover Belt Conveyor / Gnome projects found live")
        #expect(childAfter == nil)
    }

    @Test func removeLeavesAnotherRootsAutoCreatedProjectAlone() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let repo = WatchedRootRepository(writer: db.writer)
        let doomed = try await repo.add(
            WatchedRoot(hostPath: "/tmp/\(UUID().uuidString)", label: "doomed", kind: .dropFolder, bookmarkData: Data())
        )
        let survivor = try await repo.add(
            WatchedRoot(hostPath: "/tmp/\(UUID().uuidString)", label: "survivor", kind: .dropFolder, bookmarkData: Data())
        )
        let project = try await db.writer.write { conn in
            try Project(name: "Still Alive", sourceFolderPath: "/tmp/survivor-\(UUID().uuidString)").inserted(conn)
        }
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: survivor.id!, path: "/tmp/survivor/model.stl", filename: "model.stl", ext: "stl", sizeBytes: 1)
                .inserted(conn)
        }
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'confirmed')",
                arguments: [project.id!, file.id!]
            )
        }

        try await repo.remove(id: doomed.id!)

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: project.id!) }
        #expect(refetched != nil, "the sweep must not touch a project whose files belong to a root that wasn't removed")
    }
}
