import Foundation
import GRDB
import ZIPFoundation

/// Peeks an archive's contents — never decompresses — to decide whether it's worth
/// tracking at all: only archives containing a recognized model extension get a
/// `zip_files` row. Mirrors the source app's `zip_ingest.py::stage_zip_if_relevant`:
/// cheap namelist check first, so an irrelevant archive (the overwhelming majority of
/// what lands in a Downloads folder) never pays the cost of a full hash.
public struct ArchiveInspectionService: Sendable {
    private let writer: any DatabaseWriter
    private let enqueuer: any JobEnqueuer
    /// A user-granted, security-scoped-resolved location for `unar`/`7z` — see
    /// `ArchiveToolLocator.locate(preferredURL:)`. `nil` is fully supported: .7z/.rar
    /// archives are staged as `.unsupportedFormat` instead, same as always.
    private let externalToolURL: URL?

    public init(writer: any DatabaseWriter, enqueuer: any JobEnqueuer, externalToolURL: URL? = nil) {
        self.writer = writer
        self.enqueuer = enqueuer
        self.externalToolURL = externalToolURL
    }

    private static let archiveExtensions: Set<String> = ["zip", "7z", "rar"]

    public func inspect(path: String, watchedRootId: Int64) async throws {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard Self.archiveExtensions.contains(ext) else { return }
        guard !JunkFilter.isIgnorable(url.lastPathComponent) else { return }

        // Hash first (needed either way for the (path, content_hash) uniqueness check
        // that makes "reject remembered forever, but a genuinely new file at a reused
        // name gets asked about again" work) — an archive is a bounded, already-fully-
        // downloaded file, so this isn't the expensive part; decompression would be.
        guard let hash = try? FileHasher.sha256Hex(ofFileAt: url) else { return }
        let alreadyKnown = try await writer.read { conn in
            try ZipFile.filter(Column("path") == path).filter(Column("content_hash") == hash).fetchCount(conn) > 0
        }
        guard !alreadyKnown else { return }

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return }
        let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        if ext == "zip" {
            guard let namelist = try? peekZipNamelist(path: path), containsModelFile(namelist) else { return }
            try await stage(
                path: path, filename: url.lastPathComponent, sizeBytes: sizeBytes,
                watchedRootId: watchedRootId, contentHash: hash, status: .suggested
            )
        } else {
            // .7z / .rar — no native or pure-Swift support for either format.
            if let tool = ArchiveToolLocator.locate(preferredURL: externalToolURL) {
                guard let listing = try? peekViaExternalTool(path: path, tool: tool),
                      containsModelFile(scanningRawText: listing) else { return }
                try await stage(
                    path: path, filename: url.lastPathComponent, sizeBytes: sizeBytes,
                    watchedRootId: watchedRootId, contentHash: hash, status: .suggested
                )
            } else {
                // Can't determine relevance without a tool — track it defensively
                // rather than silently dropping it, with a status the admin UI can
                // explain ("install unar via Homebrew") instead of either crashing or
                // pretending the archive doesn't exist.
                try await stage(
                    path: path, filename: url.lastPathComponent, sizeBytes: sizeBytes,
                    watchedRootId: watchedRootId, contentHash: hash, status: .unsupportedFormat
                )
            }
        }
    }

    private func stage(
        path: String, filename: String, sizeBytes: Int64, watchedRootId: Int64, contentHash: String, status: ZipStatus
    ) async throws {
        let zip = ZipFile(
            watchedRootId: watchedRootId, path: path, filename: filename, sizeBytes: sizeBytes,
            status: status, contentHash: contentHash
        )
        let inserted = try await writer.write { conn in try zip.inserted(conn) }

        // Skips the review step entirely when the user has turned on auto-accept —
        // already-waiting archives from before that was turned on still need a
        // decision, since this only runs for a freshly-staged row.
        if status == .suggested {
            let autoAccept = try await writer.read { conn in
                try AppSettings.fetchOne(conn, key: AppSettings.singletonId)?.autoAcceptArchives ?? false
            }
            if autoAccept {
                try await writer.write { conn in
                    try conn.execute(sql: "UPDATE zip_files SET status = 'confirmed' WHERE id = ?", arguments: [inserted.id])
                }
                try await enqueuer.enqueue(fileId: nil, zipFileId: inserted.id, jobType: .extractZip)
            }
        }
    }

    private func peekZipNamelist(path: String) throws -> [String] {
        let archive = try Archive(url: URL(fileURLWithPath: path), accessMode: .read)
        return archive.map(\.path)
    }

    private func containsModelFile(_ paths: [String]) -> Bool {
        paths.contains { path in
            ModelExtension.all.contains((path as NSString).pathExtension.lowercased())
        }
    }

    private func peekViaExternalTool(path: String, tool: ArchiveToolLocator.Tool) throws -> String {
        let process = Process()
        switch tool.kind {
        case .unar:
            // `lsar` (list archive) ships alongside `unar` from the same Homebrew
            // formula and never extracts anything; fall back to `unar -l` (which also
            // just lists, given no destination) if `lsar` isn't sitting right next to
            // it for some reason.
            let lsarURL = tool.executableURL.deletingLastPathComponent().appendingPathComponent("lsar")
            if FileManager.default.isExecutableFile(atPath: lsarURL.path) {
                process.executableURL = lsarURL
                process.arguments = [path]
            } else {
                process.executableURL = tool.executableURL
                process.arguments = ["-l", path]
            }
        case .sevenZip:
            process.executableURL = tool.executableURL
            process.arguments = ["l", path]
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Deliberately a loose substring scan rather than strict per-tool output
    /// parsing — `unar`/`7z`'s listing formats differ and aren't worth hand-parsing
    /// precisely; detecting the *presence* of a recognized extension anywhere in the
    /// listing is enough to answer "is this archive worth reviewing."
    private func containsModelFile(scanningRawText text: String) -> Bool {
        let lowered = text.lowercased()
        return ModelExtension.all.contains { lowered.contains(".\($0)") }
    }
}
