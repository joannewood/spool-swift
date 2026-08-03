/// Narrow interface for "can enqueue a job" — ingestion/backfill code depends on this
/// instead of the concrete `JobQueue` actor, so it stays testable with a fake recorder.
public protocol JobEnqueuer: Sendable {
    @discardableResult
    func enqueue(fileId: Int64?, zipFileId: Int64?, jobType: JobType) async throws -> Job
}

extension JobQueue: JobEnqueuer {}
