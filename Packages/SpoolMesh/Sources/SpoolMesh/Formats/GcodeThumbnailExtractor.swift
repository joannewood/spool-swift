import Foundation

/// Extracts the largest embedded slicer-preview PNG from a gcode file's header
/// comments — the PrusaSlicer/SuperSlicer/OrcaSlicer/Bambu Studio convention: `;
/// thumbnail begin WxH BYTES`, base64 payload on lines prefixed `; `, `; thumbnail
/// end`, sometimes several blocks at different sizes (keep the biggest). Cheap: scans
/// only the first ~2MB of the file, since a real gcode can run to tens of MB of pure
/// toolpath and a thumbnail is always in the header — no reason to scan further.
public enum GcodeThumbnailExtractor {
    private static let scanLimitBytes = 2_000_000

    public static func extractLargestThumbnail(url: URL) throws -> Data? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        let head = try handle.read(upToCount: scanLimitBytes) ?? Data()
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            return nil
        }
        return extractLargestThumbnail(fromHeaderText: text)
    }

    static func extractLargestThumbnail(fromHeaderText text: String) -> Data? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var best: (pixels: Int, data: Data)?

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            defer { i += 1 }
            guard line.hasPrefix("; thumbnail") || line.hasPrefix(";thumbnail"), line.contains("begin") else { continue }
            guard let sizeToken = line.split(separator: " ").first(where: isDimensionToken) else { continue }
            let dims = sizeToken.split(separator: "x")
            guard dims.count == 2, let width = Int(dims[0]), let height = Int(dims[1]) else { continue }

            var base64 = ""
            var j = i + 1
            while j < lines.count {
                let bodyLine = lines[j].trimmingCharacters(in: .whitespaces)
                if bodyLine.contains("thumbnail") && bodyLine.contains("end") { break }
                if bodyLine.hasPrefix(";") {
                    base64 += bodyLine.dropFirst().trimmingCharacters(in: .whitespaces)
                }
                j += 1
            }
            i = j

            guard let data = Data(base64Encoded: base64) else { continue }
            let pixels = width * height
            if best == nil || pixels > best!.pixels {
                best = (pixels, data)
            }
        }
        return best?.data
    }

    private static func isDimensionToken(_ token: Substring) -> Bool {
        let parts = token.split(separator: "x")
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
