/// Breaks the construction-order cycle between `JobQueue` (needs `JobHandlers` up
/// front) and `IngestJobHandler` (needs a `JobEnqueuer`, which `JobQueue` itself is):
/// build handlers against a `DeferredJobEnqueuer`, construct the real `JobQueue`, then
/// `attach` it. Every call after `attach` forwards directly; any call before it is a
/// genuine programmer error (an ingest job ran before the queue that owns it exists),
/// not a recoverable runtime condition.
public actor DeferredJobEnqueuer: JobEnqueuer {
    public enum DeferredEnqueuerError: Error {
        case notYetAttached
    }

    private var target: (any JobEnqueuer)?

    public init() {}

    public func attach(_ target: any JobEnqueuer) {
        self.target = target
    }

    public func enqueue(fileId: Int64?, zipFileId: Int64?, jobType: JobType) async throws -> Job {
        guard let target else { throw DeferredEnqueuerError.notYetAttached }
        return try await target.enqueue(fileId: fileId, zipFileId: zipFileId, jobType: jobType)
    }
}
