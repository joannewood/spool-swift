import Foundation
import GRDB

/// A queued unit of work. Exactly one of `fileId`/`zipFileId` is set depending on
/// `jobType` (extract_zip references a zip, everything else a file) — mirroring the
/// source app's `jobs` table, which allowed both FKs for the same reason.
public struct Job: SpoolIdentifiableRecord, Sendable {
    public static let databaseTableName = "jobs"

    public var id: Int64?
    public var fileId: Int64?
    public var zipFileId: Int64?
    public var jobType: JobType
    public var status: JobStatus
    public var error: String?
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: Int64? = nil,
        fileId: Int64? = nil,
        zipFileId: Int64? = nil,
        jobType: JobType,
        status: JobStatus = .queued,
        error: String? = nil,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.fileId = fileId
        self.zipFileId = zipFileId
        self.jobType = jobType
        self.status = status
        self.error = error
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}
