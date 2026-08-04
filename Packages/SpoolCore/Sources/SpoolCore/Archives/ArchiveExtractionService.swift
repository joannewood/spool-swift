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
        /// `.7z`/`.rar` can never reach `confirmed` — `ArchiveInspectionService` always
        /// stages them as `.unsupportedFormat` (no in-sandbox way to run an external
        /// `unar`/`7z`; see its doc comment) — so this is only reachable if that
        /// invariant is ever broken elsewhere, not a real runtime path today.
        case unsupportedArchiveFormat
    }

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
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

            guard archiveURL.pathExtension.lowercased() == "zip" else {
                throw ExtractionError.unsupportedArchiveFormat
            }
            // ZIPFoundation's `unzipItem` already guards each entry with
            // `entryURL.isContained(in: destinationURL)` before writing anything — the
            // zip-slip protection this needs, provided by the library itself.
            try FileManager.default.unzipItem(at: archiveURL, to: destinationURL)

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

    public init(writer: any DatabaseWriter) {
        self.extraction = ArchiveExtractionService(writer: writer)
    }

    public func handle(_ job: Job) async throws {
        guard let zipFileId = job.zipFileId else { throw HandlerError.missingZipFileId }
        try await extraction.extract(zipFileId: zipFileId)
    }
}
