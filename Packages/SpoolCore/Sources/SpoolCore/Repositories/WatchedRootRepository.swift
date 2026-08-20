import Foundation
import GRDB

/// CRUD over `watched_roots`, shared by onboarding (add a new root), the watcher/job
/// handlers (read active roots + bookmarks to resolve access), and the settings UI
/// (pause/relabel/remove a root).
public struct WatchedRootRepository: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func fetchAll() async throws -> [WatchedRoot] {
        try await writer.read { conn in
            try WatchedRoot.order(Column("id")).fetchAll(conn)
        }
    }

    public func fetchActive() async throws -> [WatchedRoot] {
        try await writer.read { conn in
            try WatchedRoot.filter(Column("active") == true).order(Column("id")).fetchAll(conn)
        }
    }

    @discardableResult
    public func add(_ root: WatchedRoot) async throws -> WatchedRoot {
        try await writer.write { conn in try root.inserted(conn) }
    }

    /// Deleting the root row cascades its `files`/`zip_files`/`sidecar_files` away at
    /// the SQLite FK level (`ON DELETE CASCADE`) — fast, but it means none of
    /// `FileService`/`ProjectService`'s usual per-file `ProjectCleanup` calls ever run,
    /// so any auto-created project this root's files were the last members of would
    /// otherwise be left behind as a dead, empty shell. The sweep runs in the same
    /// transaction to catch exactly that.
    public func remove(id: Int64) async throws {
        try await writer.write { conn in
            _ = try WatchedRoot.deleteOne(conn, id: id)
            try ProjectCleanup.sweepEmptyAutoCreated(conn: conn)
        }
    }

    public func setActive(id: Int64, active: Bool) async throws {
        try await writer.write { conn in
            try conn.execute(sql: "UPDATE watched_roots SET active = ? WHERE id = ?", arguments: [active, id])
        }
    }

    /// `ingestMode` is only actually applied for `kind == .library` roots — a drop
    /// folder and a downloads root each have exactly one sane ingest mode implied by
    /// their role (`.indexInPlace` / `.relocateToDropfolder` respectively, fixed at
    /// grant time in `RootsViewModel.addRoot`), so this is the same server-side
    /// backstop the source app's `update_watched_root` describes: flipping a downloads
    /// root to `.indexInPlace` would silently disable the one thing that root exists
    /// to do, and a drop folder relocating into itself is a real, untested code path.
    public func update(id: Int64, label: String, ingestMode: RootIngestMode, active: Bool) async throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        try await writer.write { conn in
            try conn.execute(sql: """
                UPDATE watched_roots SET
                    label = ?,
                    ingest_mode = CASE WHEN kind = 'library' THEN ? ELSE ingest_mode END,
                    active = ?
                WHERE id = ?
                """, arguments: [trimmed.isEmpty ? label : trimmed, ingestMode.rawValue, active, id])
        }
    }

    public func updateLastScanned(id: Int64, date: Date) async throws {
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE watched_roots SET last_scanned_at = ? WHERE id = ?",
                arguments: [date, id]
            )
        }
    }

    /// Re-persists a re-derived bookmark for a root whose stored one resolved stale
    /// (e.g. after a volume rename) — keeps the row's bookmark valid without forcing
    /// the user to re-grant access via a fresh `NSOpenPanel` prompt.
    public func updateBookmarkData(id: Int64, data: Data) async throws {
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE watched_roots SET bookmark_data = ? WHERE id = ?",
                arguments: [data, id]
            )
        }
    }
}
