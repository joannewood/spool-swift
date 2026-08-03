import Foundation
import GRDB

/// File-level mutations that don't belong to any other service (tags, projects, print
/// metadata/log all have their own) — the display-name override shown instead of the
/// on-disk filename, and deleting a file outright (the library grid's multi-select
/// "Delete" action).
public struct FileService: Sendable {
    public enum DeletionError: Error {
        /// The one hard rule shared with `DuplicateService`: the read-only Library
        /// root is never written to or deleted from — its copies can only be removed
        /// by the user, outside Spool, in Finder.
        case cannotDeleteFromLibraryRoot
    }

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// A blank/whitespace-only name clears the override (falls back to showing the
    /// real filename again), matching the source app's `display_name or None`.
    public func setDisplayName(fileId: Int64, to displayName: String) async throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE files SET display_name = ? WHERE id = ?",
                arguments: [trimmed.isEmpty ? nil : trimmed, fileId]
            )
        }
    }

    /// Trashes the real file (recoverable, same as `DuplicateService.deleteDuplicate`),
    /// then removes the DB row only after that succeeds, so a failed/denied delete
    /// never leaves a "phantom" untracked-but-still-present file.
    public func delete(fileId: Int64) async throws {
        guard let file = try await writer.read({ conn in try SpoolFile.fetchOne(conn, id: fileId) }) else { return }
        guard let root = try await writer.read({ conn in try WatchedRoot.fetchOne(conn, id: file.watchedRootId) })
        else { return }
        guard root.kind != .library else { throw DeletionError.cannotDeleteFromLibraryRoot }

        try FileManager.default.trashItem(at: URL(fileURLWithPath: file.path), resultingItemURL: nil)

        try await writer.write { conn in
            _ = try SpoolFile.deleteOne(conn, id: fileId)
        }
    }

    /// Bulk delete for the library grid's multi-select — deletes what it can and
    /// silently skips the rest (a Library-root file, a permission failure) rather than
    /// aborting the whole batch on the first problem. Returns how many actually
    /// deleted, and the filenames of any that were skipped because they live in the
    /// read-only Library root.
    @discardableResult
    public func deleteFiles(fileIds: [Int64]) async throws -> (deletedCount: Int, skippedLibraryFilenames: [String]) {
        var deletedCount = 0
        var skippedLibraryFilenames: [String] = []
        for fileId in fileIds {
            do {
                try await delete(fileId: fileId)
                deletedCount += 1
            } catch DeletionError.cannotDeleteFromLibraryRoot {
                if let file = try? await writer.read({ conn in try SpoolFile.fetchOne(conn, id: fileId) }) {
                    skippedLibraryFilenames.append(file.filename)
                }
            }
        }
        return (deletedCount, skippedLibraryFilenames)
    }
}
