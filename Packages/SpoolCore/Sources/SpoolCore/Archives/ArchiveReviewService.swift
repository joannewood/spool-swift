import Foundation
import GRDB

/// Admin-page actions on a staged archive: confirm (extract), reject (remembered until
/// content changes — see `ArchiveInspectionService`'s (path, content_hash) uniqueness),
/// or un-reject (back to pending, in case of a change of mind).
public struct ArchiveReviewService: Sendable {
    private let writer: any DatabaseWriter
    private let enqueuer: any JobEnqueuer
    private let inspection: ArchiveInspectionService

    public init(writer: any DatabaseWriter, enqueuer: any JobEnqueuer, externalArchiveToolDirectory: URL? = nil) {
        self.writer = writer
        self.enqueuer = enqueuer
        self.inspection = ArchiveInspectionService(writer: writer, enqueuer: enqueuer, externalToolDirectory: externalArchiveToolDirectory)
    }

    /// See `ArchiveInspectionService.recheckUnsupported` — the "Check Again" action for
    /// an archive stuck as unsupported from before an external tool was configured.
    @discardableResult
    public func recheckUnsupported(zipFileId: Int64) async throws -> Bool {
        try await inspection.recheckUnsupported(zipFileId: zipFileId)
    }

    public func pendingArchives() async throws -> [ZipFile] {
        try await writer.read { conn in
            try ZipFile.filter(Column("status") == ZipStatus.suggested.rawValue).fetchAll(conn)
        }
    }

    public func unsupportedArchives() async throws -> [ZipFile] {
        try await writer.read { conn in
            try ZipFile.filter(Column("status") == ZipStatus.unsupportedFormat.rawValue).fetchAll(conn)
        }
    }

    public func rejectedArchives() async throws -> [ZipFile] {
        try await writer.read { conn in
            try ZipFile.filter(Column("status") == ZipStatus.rejected.rawValue).fetchAll(conn)
        }
    }

    @discardableResult
    public func confirm(zipFileId: Int64) async throws -> Job {
        try await setStatus(zipFileId: zipFileId, status: .confirmed)
        return try await enqueuer.enqueue(fileId: nil, zipFileId: zipFileId, jobType: .extractZip)
    }

    public func reject(zipFileId: Int64) async throws {
        try await setStatus(zipFileId: zipFileId, status: .rejected)
    }

    public func unreject(zipFileId: Int64) async throws {
        try await setStatus(zipFileId: zipFileId, status: .suggested)
    }

    /// Confirms (extracts) just the given subset — the "Confirm Selected" bulk action
    /// for a checked-off subset of the pending-archives review queue.
    public func confirm(zipFileIds: [Int64]) async throws {
        for id in zipFileIds {
            _ = try await confirm(zipFileId: id)
        }
    }

    /// Confirms (extracts) every currently-pending archive in one action — same
    /// "no per-row id list from the client" reasoning as the suggestion queues'
    /// accept-all. Extraction is a real, irreversible action (deletes the original zip
    /// after extracting), but that's exactly what this button says it does.
    @discardableResult
    public func confirmAll() async throws -> Int {
        let pending = try await pendingArchives()
        for zip in pending {
            guard let id = zip.id else { continue }
            _ = try await confirm(zipFileId: id)
        }
        return pending.count
    }

    private func setStatus(zipFileId: Int64, status: ZipStatus) async throws {
        try await writer.write { conn in
            try conn.execute(sql: "UPDATE zip_files SET status = ? WHERE id = ?", arguments: [status.rawValue, zipFileId])
        }
    }
}
