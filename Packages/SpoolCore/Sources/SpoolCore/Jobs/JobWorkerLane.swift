import Foundation
import GRDB

/// Claims and runs jobs of a fixed set of `JobType`s, up to `concurrency` at once.
///
/// This replaces Postgres's `SELECT ... FOR UPDATE SKIP LOCKED`: that exists to
/// arbitrate multiple *worker processes* racing for the same row, but GRDB's
/// `DatabasePool` only ever has one writer connection, so the race it guards against
/// can't happen here — claiming collapses to a single `UPDATE ... RETURNING` statement.
///
/// Two lanes exist app-wide (see `JobQueue`) mirroring the source app's two-container
/// split (`worker` vs `worker-step`), so a slow STEP-tessellation backlog can never
/// block quick mesh renders.
public actor JobWorkerLane {
    private let jobTypes: Set<JobType>
    private let concurrency: Int
    private let writer: any DatabaseWriter
    private let handlers: JobHandlers
    private let pollInterval: Duration

    private var inFlight = 0
    private var isRunning = false
    private var pollTask: Task<Void, Never>?

    public init(
        jobTypes: Set<JobType>,
        concurrency: Int,
        writer: any DatabaseWriter,
        handlers: JobHandlers,
        pollInterval: Duration = .seconds(5)
    ) {
        self.jobTypes = jobTypes
        self.concurrency = max(1, concurrency)
        self.writer = writer
        self.handlers = handlers
        self.pollInterval = pollInterval
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        // Defensive fallback in case a nudge is ever missed (e.g. an enqueue that
        // raced a stop/start) — cheap insurance against a silently stalled lane.
        pollTask = Task { [weak self] in
            while let self, await self.isRunning {
                try? await Task.sleep(for: self.pollInterval)
                await self.nudge()
            }
        }
        nudge()
    }

    public func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
    }

    public func nudge() {
        guard isRunning else { return }
        Task { await drain() }
    }

    private func drain() async {
        while isRunning, inFlight < concurrency {
            guard let job = try? await claimNext() else { break }
            inFlight += 1
            Task { [job] in
                await self.run(job)
                await self.jobFinished()
            }
        }
    }

    private func jobFinished() {
        inFlight -= 1
        nudge()
    }

    private func claimNext() async throws -> Job? {
        let types = Array(jobTypes)
        let placeholders = types.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            UPDATE jobs
            SET status = 'running'
            WHERE id = (
                SELECT id FROM jobs
                WHERE status = 'queued' AND job_type IN (\(placeholders))
                ORDER BY created_at ASC
                LIMIT 1
            )
            RETURNING *;
            """
        return try await writer.write { conn in
            try Job.fetchOne(conn, sql: sql, arguments: StatementArguments(types.map(\.rawValue)))
        }
    }

    private func run(_ job: Job) async {
        do {
            try await handlers.handler(for: job.jobType).handle(job)
            await complete(job, status: .done, error: nil)
        } catch {
            await complete(job, status: .failed, error: String(describing: error))
        }
    }

    private func complete(_ job: Job, status: JobStatus, error: String?) async {
        try? await writer.write { conn in
            var updated = job
            updated.status = status
            updated.error = error
            updated.completedAt = Date()
            try updated.update(conn)
        }
    }
}
