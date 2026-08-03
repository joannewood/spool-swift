import Foundation
import GRDB
import ZIPFoundation

/// Extracts a confirmed archive, deletes the original, and (for `relocate_to_dropfolder`
/// roots — i.e. Downloads) moves the extracted folder into the drop folder, matching
/// the source app's `zip_extract.py` exactly.
public struct ArchiveExtractionService: Sendable {
    public enum ExtractionError: Error {
        case zipFileNotFound
        case rootNotFound
        case cannotExtractIntoReadOnlyRoot
        case noToolAvailableForFormat
        case externalToolFailed(status: Int32)
    }

    private let writer: any DatabaseWriter
    /// See `ArchiveInspectionService.externalToolDirectory` — same user-granted, security-
    /// scoped-resolved `unar`/`7z` location, `nil` fully supported.
    private let externalToolDirectory: URL?

    public init(writer: any DatabaseWriter, externalToolDirectory: URL? = nil) {
        self.writer = writer
        self.externalToolDirectory = externalToolDirectory
    }

    public func extract(zipFileId: Int64) async throws {
        guard let zip = try await writer.read({ conn in try ZipFile.fetchOne(conn, id: zipFileId) }) else {
            throw ExtractionError.zipFileNotFound
        }
        guard let root = try await writer.read({ conn in try WatchedRoot.fetchOne(conn, id: zip.watchedRootId) })
        else { throw ExtractionError.rootNotFound }

        do {
            // Fails loudly, by design — an `index_in_place` (Library) root is never
            // supposed to be written to, matching the source app's exact behavior when
            // this happens (a real, encountered case, not just a defensive guess).
            guard root.kind != .library else { throw ExtractionError.cannotExtractIntoReadOnlyRoot }

            let archiveURL = URL(fileURLWithPath: zip.path)
            let stem = archiveURL.deletingPathExtension().lastPathComponent
            var destinationURL = uniqueURL(baseName: stem, in: archiveURL.deletingLastPathComponent())

            if archiveURL.pathExtension.lowercased() == "zip" {
                // ZIPFoundation's `unzipItem` already guards each entry with
                // `entryURL.isContained(in: destinationURL)` before writing anything —
                // the zip-slip protection this needs, provided by the library itself.
                try FileManager.default.unzipItem(at: archiveURL, to: destinationURL)
            } else {
                try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
                try extractViaExternalTool(archiveURL: archiveURL, to: destinationURL)
            }

            try FileManager.default.removeItem(at: archiveURL)

            if root.ingestMode == .relocateToDropfolder,
               let dropRoot = try await writer.read({ conn in
                   try WatchedRoot.filter(Column("kind") == RootKind.dropFolder.rawValue).fetchOne(conn)
               }) {
                let dropFolderURL = URL(fileURLWithPath: dropRoot.hostPath)
                let relocatedURL = uniqueURL(baseName: destinationURL.lastPathComponent, in: dropFolderURL)
                try FileManager.default.moveItem(at: destinationURL, to: relocatedURL)
                destinationURL = relocatedURL
            }

            try await writer.write { conn in _ = try ZipFile.deleteOne(conn, id: zipFileId) }
        } catch {
            // Surfaces in Admin via `zip_files.error` rather than crashing the
            // extraction job — the row is deliberately kept (not deleted) on failure,
            // unlike the success path, so there's something to look at.
            try await writer.write { conn in
                try conn.execute(sql: "UPDATE zip_files SET error = ? WHERE id = ?", arguments: ["\(error)", zipFileId])
            }
            throw error
        }
    }

    private func extractViaExternalTool(archiveURL: URL, to destinationURL: URL) throws {
        guard let tool = ArchiveToolLocator.locate(preferredDirectory: externalToolDirectory) else { throw ExtractionError.noToolAvailableForFormat }
        let process = Process()
        switch tool.kind {
        case .unar:
            process.executableURL = tool.executableURL
            process.arguments = ["-o", destinationURL.path, archiveURL.path]
        case .sevenZip:
            process.executableURL = tool.executableURL
            process.arguments = ["x", "-o\(destinationURL.path)", archiveURL.path]
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExtractionError.externalToolFailed(status: process.terminationStatus)
        }
    }

    private func uniqueURL(baseName: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(baseName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) (\(suffix))")
            suffix += 1
        }
        return candidate
    }
}

/// The `extract_zip` job handler — the job queue's entry point into
/// `ArchiveExtractionService`.
public struct ExtractZipJobHandler: JobHandler {
    public enum HandlerError: Error {
        case missingZipFileId
    }

    private let extraction: ArchiveExtractionService

    public init(writer: any DatabaseWriter, externalToolDirectory: URL? = nil) {
        self.extraction = ArchiveExtractionService(writer: writer, externalToolDirectory: externalToolDirectory)
    }

    public func handle(_ job: Job) async throws {
        guard let zipFileId = job.zipFileId else { throw HandlerError.missingZipFileId }
        try await extraction.extract(zipFileId: zipFileId)
    }
}
