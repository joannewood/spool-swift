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
    struct TimedOutError: Error, CustomStringConvertible {
        let seconds: Double
        var description: String { "handler did not finish within \(Int(seconds))s — treated as hung, not still-running" }
    }

    /// Resumes a `CheckedContinuation` at most once — whichever of the handler call or
    /// the timeout finishes first wins; the other's eventual result (if it ever
    /// arrives) is silently dropped rather than triggering Swift's fatal "continuation
    /// resumed twice" error.
    private actor OneShotResume {
        private var continuation: CheckedContinuation<Result<Void, Error>, Never>?
        init(_ continuation: CheckedContinuation<Result<Void, Error>, Never>) {
            self.continuation = continuation
        }
        func resume(with result: Result<Void, Error>) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

    private let jobTypes: Set<JobType>
    private let concurrency: Int
    private let writer: any DatabaseWriter
    private let handlers: JobHandlers
    private let pollInterval: Duration
    private let handlerTimeoutSeconds: Double

    private var inFlight = 0
    private var isRunning = false
    private var pollTask: Task<Void, Never>?

    public init(
        jobTypes: Set<JobType>,
        concurrency: Int,
        writer: any DatabaseWriter,
        handlers: JobHandlers,
        pollInterval: Duration = .seconds(5),
        handlerTimeoutSeconds: Double = 180
    ) {
        self.jobTypes = jobTypes
        self.concurrency = max(1, concurrency)
        self.writer = writer
        self.handlers = handlers
        self.pollInterval = pollInterval
        self.handlerTimeoutSeconds = handlerTimeoutSeconds
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

    /// Confirmed live as a real bug: a single stuck handler call (a STEP-tessellation
    /// job whose Swift-side thumbnail render never returned, despite the converter
    /// process itself finishing in under a second when run standalone) permanently
    /// froze the slow lane — `concurrency = 1` there means `inFlight` never drops back
    /// below `concurrency`, so `drain()` never claims another job, forever.
    ///
    /// Deliberately *not* `withThrowingTaskGroup` for the race: a task group's own
    /// scope-exit waits for every child it spawned to actually finish, cancelled or
    /// not — cooperative cancellation only helps a handler that itself checks for it,
    /// so a truly hung handler would keep the group (and this whole function) hanging
    /// right along with it, defeating the entire point. Racing two independent,
    /// unstructured `Task`s against a single one-shot continuation instead means
    /// whichever finishes first lets `run()` return immediately; a loser that never
    /// finishes just keeps running unobserved rather than blocking anything.
    private func run(_ job: Job) async {
        let outcome: Result<Void, Error> = await withCheckedContinuation { continuation in
            let oneShot = OneShotResume(continuation)
            Task {
                do {
                    try await self.handlers.handler(for: job.jobType).handle(job)
                    await oneShot.resume(with: .success(()))
                } catch {
                    await oneShot.resume(with: .failure(error))
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(self.handlerTimeoutSeconds))
                await oneShot.resume(with: .failure(TimedOutError(seconds: self.handlerTimeoutSeconds)))
            }
        }
        switch outcome {
        case .success:
            await complete(job, status: .done, error: nil)
        case .failure(let error):
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
