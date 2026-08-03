import Foundation

/// Locates an external tool capable of listing/extracting `.7z`/`.rar` contents —
/// there's no native Apple or pure-Swift support for either format. `unar`
/// (commonly installed via Homebrew, from The Unarchiver project) is preferred since
/// it handles both formats with one consistent CLI; `7z`/`7zz` is the fallback for
/// `.7z` specifically.
public enum ArchiveToolLocator {
    private static let searchPaths = [
        "/opt/homebrew/bin/unar", "/usr/local/bin/unar",
        "/opt/homebrew/bin/7zz", "/usr/local/bin/7zz",
        "/opt/homebrew/bin/7z", "/usr/local/bin/7z",
    ]

    public struct Tool: Sendable {
        public let executableURL: URL
        public let kind: Kind

        public enum Kind: Sendable { case unar, sevenZip }
    }

    private static let candidateNames = ["unar", "7zz", "7z"]

    /// `preferredDirectory` is a user-granted, security-scoped-bookmarked *folder* (see
    /// `AppSettings.archiveToolBookmarkData`) — checked first, and in practice the
    /// *only* thing that works in the real sandboxed app: confirmed live that
    /// `isExecutableFile` returns false for every one of the fixed `searchPaths` below
    /// under the app's actual shipped entitlements, even when the binary is genuinely
    /// installed there, because they're outside the sandbox container and nothing
    /// grants access to them. The fixed-path scan is kept as a fallback because it
    /// *does* work in an unsandboxed `swift test`/debug context.
    ///
    /// A *folder* bookmark, not a bookmark directly on the executable — confirmed live
    /// (and it's a documented, known macOS bug) that `.bookmarkData(.withSecurityScope)`
    /// reliably fails ("Could not open() the item") for a symlink, which is exactly
    /// what every Homebrew-installed `/opt/homebrew/bin/*` entry is. Granting the real,
    /// non-symlink containing directory instead — the same folder-bookmark mechanism
    /// already proven working for watched roots — and searching within it for a known
    /// name sidesteps the bug entirely rather than working around it file-by-file.
    public static func locate(preferredDirectory: URL? = nil, fileManager: FileManager = .default) -> Tool? {
        if let preferredDirectory {
            for name in candidateNames {
                let candidate = preferredDirectory.appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: candidate.path) {
                    return tool(at: candidate)
                }
            }
        }
        for path in searchPaths where fileManager.isExecutableFile(atPath: path) {
            return tool(at: URL(fileURLWithPath: path))
        }
        return nil
    }

    private static func tool(at url: URL) -> Tool {
        let kind: Tool.Kind = url.lastPathComponent.lowercased().contains("unar") ? .unar : .sevenZip
        return Tool(executableURL: url, kind: kind)
    }
}
