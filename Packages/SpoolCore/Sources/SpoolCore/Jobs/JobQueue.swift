import Foundation
import GRDB

/// App-wide job queue: two lanes (fast/slow, see `JobWorkerLane`) sharing one SQLite
/// writer. Enqueuing writes a row and immediately nudges the right lane — no polling
/// latency for the common case, with each lane's own low-frequency poll as a fallback.
public actor JobQueue {
    private let writer: any DatabaseWriter
    private let fastLane: JobWorkerLane
    private let slowLane: JobWorkerLane

    public init(
        writer: any DatabaseWriter,
        handlers: JobHandlers,
        fastConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount,
        slowConcurrency: Int = 1
    ) {
        self.writer = writer
        self.fastLane = JobWorkerLane(
            jobTypes: JobType.fastLane, concurrency: fastConcurrency, writer: writer, handlers: handlers
        )
        self.slowLane = JobWorkerLane(
            jobTypes: JobType.slowLane, concurrency: slowConcurrency, writer: writer, handlers: handlers
        )
    }

    public func start() async {
        // Crash recovery: this app runs exactly one process with no horizontal
        // scaling, so anything still 'running' at startup can only be orphaned from a
        // previous crash — unconditionally requeue it, mirroring the source app's
        // `requeue_orphaned_jobs`.
        try? await writer.write { conn in
            try conn.execute(sql: "UPDATE jobs SET status = 'queued' WHERE status = 'running'")
        }
        await fastLane.start()
        await slowLane.start()
    }

    public func stop() async {
        await fastLane.stop()
        await slowLane.stop()
    }

    @discardableResult
    public func enqueue(fileId: Int64? = nil, zipFileId: Int64? = nil, jobType: JobType) async throws -> Job {
        let job = Job(fileId: fileId, zipFileId: zipFileId, jobType: jobType)
        let inserted = try await writer.write { conn in
            try job.inserted(conn)
        }
        if JobType.fastLane.contains(jobType) {
            await fastLane.nudge()
        } else {
            await slowLane.nudge()
        }
        return inserted
    }
}
