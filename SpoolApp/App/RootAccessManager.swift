import Combine
import Foundation
import SpoolCore
import SpoolFS

/// Holds one active `SecurityScopedAccess` per watched root for the app's lifetime —
/// resolved once at launch (and again immediately after a new root is granted), never
/// re-resolved per file operation. This is the direct replacement for the source app's
/// always-mounted Docker bind mounts: as long as the app is running, every active root
/// is accessible.
@MainActor
final class RootAccessManager: ObservableObject {
    private let repository: WatchedRootRepository
    private var access: [Int64: SecurityScopedAccess] = [:]

    init(repository: WatchedRootRepository) {
        self.repository = repository
    }

    /// Resolves every active root's bookmark. A stale bookmark (e.g. after a volume
    /// rename) is silently re-derived and re-persisted rather than forcing the user to
    /// re-grant access — the resolved URL is still valid for this launch either way.
    func resolveAll() async throws {
        for root in try await repository.fetchActive() {
            try resolve(root)
        }
    }

    @discardableResult
    func resolve(_ root: WatchedRoot) throws -> URL {
        guard let id = root.id else { preconditionFailure("root must be persisted before resolving access") }
        let scoped = try SecurityScopedAccess.resolve(bookmarkData: root.bookmarkData)
        access[id]?.stop()
        access[id] = scoped
        if scoped.isStale {
            Task { try? await refreshStaleBookmark(rootId: id, url: scoped.url) }
        }
        return scoped.url
    }

    func url(forRootId id: Int64) -> URL? {
        access[id]?.url
    }

    private func refreshStaleBookmark(rootId: Int64, url: URL) async throws {
        let freshData = try SecurityScopedBookmark.create(for: url)
        try await repository.updateBookmarkData(id: rootId, data: freshData)
    }
}
