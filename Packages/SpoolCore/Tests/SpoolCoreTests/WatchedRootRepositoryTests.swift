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
}
