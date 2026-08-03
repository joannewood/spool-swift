import Foundation

/// Wraps macOS's security-scoped bookmark APIs for the sandboxed app's watched-root
/// folders. A user grants a folder once via `NSOpenPanel` (in `SpoolApp`, which owns
/// the panel); the resulting bookmark is persisted in `WatchedRoot.bookmarkData` and
/// re-resolved on every launch — this is the entire replacement for the source app's
/// `host-helper` process and its Full-Disk-Access dance.
public enum SecurityScopedBookmark {
    public enum BookmarkError: Error, Equatable {
        case resolutionFailed
    }

    /// Captures a security-scoped bookmark for a URL the user just granted access to
    /// (typically straight out of an `NSOpenPanel` result).
    public static func create(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves previously-persisted bookmark data back into a URL. `isStale` is
    /// surfaced (not thrown) — a stale bookmark still resolves to a usable URL for this
    /// launch; the caller should re-derive and persist a fresh bookmark from it rather
    /// than force a user to re-grant access, which handles e.g. a volume rename.
    public static func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
}

/// RAII-style holder for an active security scope: call `resolve(bookmarkData:)`, use
/// `.url` while the returned `SecurityScopedAccess` is alive, and let it go out of scope
/// (or call `stop()` explicitly) to release access. Holding one per watched root for the
/// app's lifetime is the native equivalent of the source app's always-mounted Docker
/// bind mounts.
public final class SecurityScopedAccess {
    public let url: URL
    public let isStale: Bool
    private var isAccessing = false

    public static func resolve(bookmarkData: Data) throws -> SecurityScopedAccess {
        let (url, isStale) = try SecurityScopedBookmark.resolve(bookmarkData)
        let access = SecurityScopedAccess(url: url, isStale: isStale)
        access.start()
        return access
    }

    init(url: URL, isStale: Bool) {
        self.url = url
        self.isStale = isStale
    }

    @discardableResult
    private func start() -> Bool {
        guard !isAccessing else { return true }
        isAccessing = url.startAccessingSecurityScopedResource()
        return isAccessing
    }

    public func stop() {
        guard isAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    deinit {
        stop()
    }
}
