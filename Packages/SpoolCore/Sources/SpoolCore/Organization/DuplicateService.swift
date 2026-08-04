import Foundation
import GRDB

public struct DuplicateGroup: Sendable, Identifiable {
    public var id: String { contentHash }
    public let contentHash: String
    /// Oldest first — the review UI's "select all" leaves the first (oldest,
    /// presumably-original) copy unchecked by default, same as the source app.
    public let files: [SpoolFile]
}

/// Groups active files by identical `content_hash` directly (not by walking
/// `duplicate_of` relationship rows) — same hash always means byte-identical content,
/// which answers the whole "are these duplicates" question without needing a
/// relationship row to exist for every pair.
public struct DuplicateService: Sendable {
    public enum DeletionError: Error {
        /// The source app's one hard rule: the read-only Library root is never
        /// written to or deleted from — its copies can only be removed by the user,
        /// outside Spool, in Finder.
        case cannotDeleteFromLibraryRoot
    }

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func listDuplicateGroups() async throws -> [DuplicateGroup] {
        try await writer.read { conn in
            let hashes = try String.fetchAll(conn, sql: """
                SELECT content_hash FROM files
                WHERE status = 'active' AND content_hash IS NOT NULL
                GROUP BY content_hash HAVING COUNT(*) > 1
                """)
            var groups: [DuplicateGroup] = []
            groups.reserveCapacity(hashes.count)
            for hash in hashes {
                let files = try SpoolFile
                    .filter(Column("content_hash") == hash)
                    .filter(Column("status") == FileStatus.active.rawValue)
                    .order(Column("first_seen_at").asc)
                    .fetchAll(conn)
                groups.append(DuplicateGroup(contentHash: hash, files: files))
            }
            return groups
        }
    }

    /// Trashes the real file (recoverable — a deliberate improvement over the source
    /// app's irreversible `os.remove`), then removes the DB row only after that
    /// succeeds, so a failed/denied delete never leaves a "phantom" untracked-but-
    /// still-present file. Also cleans up any project left with zero files as a
    /// result — a deleted file is often the sole member of an auto-created project for
    /// what turned out to be a duplicate download's own folder. Affected project ids
    /// are captured *before* the delete, not after: `project_files` rows CASCADE away
    /// with the file.
    public func deleteDuplicate(fileId: Int64) async throws {
        guard let file = try await writer.read({ conn in try SpoolFile.fetchOne(conn, id: fileId) }) else { return }
        guard let root = try await writer.read({ conn in try WatchedRoot.fetchOne(conn, id: file.watchedRootId) })
        else { return }
        guard root.kind != .library else { throw DeletionError.cannotDeleteFromLibraryRoot }

        try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)

        try await writer.write { conn in
            let affectedProjectIds = try Int64.fetchAll(
                conn, sql: "SELECT DISTINCT project_id FROM project_files WHERE file_id = ?", arguments: [fileId]
            )
            _ = try SpoolFile.deleteOne(conn, id: fileId)
            for projectId in affectedProjectIds {
                try ProjectCleanup.deleteIfEmptyAndAutoCreated(projectId: projectId, conn: conn)
            }
        }
    }

    /// Deletes exactly the given files — the "Delete Selected" bulk action for a
    /// manually checked-off subset of the duplicates queue, as opposed to
    /// `deleteAllDuplicates`'s own per-group "keep one" default. `try?` per file
    /// matches `deleteAllDuplicates`'s resilience: one denied/failed delete (e.g. a
    /// Library-root file slipping through) doesn't abort the rest of the batch.
    public func deleteDuplicates(fileIds: [Int64]) async throws {
        for id in fileIds {
            try? await deleteDuplicate(fileId: id)
        }
    }

    /// Deletes every "extra" copy across every duplicate group in one action. Per
    /// group: if no copy lives in the read-only Library root, keeps the oldest
    /// (`files` is already oldest-first) and deletes every other copy; if at least one
    /// copy *does* live in Library, that copy is a forced keeper Spool can never
    /// delete anyway, so every deletable copy is removed regardless of age instead —
    /// same "down to one true copy" outcome either way. A group where every copy is in
    /// Library is left untouched entirely, nothing there is touchable. Reuses
    /// `deleteDuplicate` per file so this gets the exact same trash-then-remove-row
    /// safety as deleting one file by hand — a failure on one file (e.g. permission
    /// denied) doesn't abort the rest of the batch.
    @discardableResult
    public func deleteAllDuplicates() async throws -> Int {
        var deletedCount = 0
        for group in try await listDuplicateGroups() {
            for fileId in try await filesToDeleteByDefault(in: group) {
                try? await deleteDuplicate(fileId: fileId)
                deletedCount += 1
            }
        }
        return deletedCount
    }

    private func filesToDeleteByDefault(in group: DuplicateGroup) async throws -> [Int64] {
        var isLibraryByFileId: [Int64: Bool] = [:]
        for file in group.files {
            guard let fileId = file.id,
                  let root = try await writer.read({ conn in try WatchedRoot.fetchOne(conn, id: file.watchedRootId) })
            else { continue }
            isLibraryByFileId[fileId] = root.kind == .library
        }
        let deletable = group.files.filter { isLibraryByFileId[$0.id ?? -1] == false }
        guard !deletable.isEmpty else { return [] }

        if deletable.count == group.files.count {
            return group.files.dropFirst().compactMap(\.id)
        }
        return deletable.compactMap(\.id)
    }
}
