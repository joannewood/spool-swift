import CryptoKit
import Foundation

/// Streaming SHA-256 over a file's real bytes, 1MB chunks — the same algorithm/chunk
/// size as the source app's `hashing.py`, so a file's identity (used for dedupe,
/// duplicate-of suggestions, and move detection) is stable across the rewrite.
public enum FileHasher {
    public enum HashError: Error {
        case cannotOpenFile(URL)
    }

    public static func sha256Hex(ofFileAt url: URL, chunkSize: Int = 1_048_576) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw HashError.cannotOpenFile(url)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
