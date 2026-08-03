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

    public static func locate(fileManager: FileManager = .default) -> Tool? {
        for path in searchPaths where fileManager.isExecutableFile(atPath: path) {
            let kind: Tool.Kind = path.contains("unar") ? .unar : .sevenZip
            return Tool(executableURL: URL(fileURLWithPath: path), kind: kind)
        }
        return nil
    }
}
