import Foundation
import GRDB
import Testing
@testable import SpoolCore

/// Records which jobs it was asked to handle, so tests can assert dispatch/ordering
/// without depending on real ingestion/render logic (not implemented until M1+).
private actor RecordingHandler: JobHandler {
    private(set) var handledIds: [Int64] = []
    var shouldFail = false

    func handle(_ job: Job) async throws {
        if shouldFail {
            throw TestError.intentional
        }
        handledIds.append(job.id!)
    }

    enum TestError: Error { case intentional }
}

@Suite struct JobQueueTests {
    private func makeQueue(
        db: SQLiteSpoolDatabase,
        recorder: RecordingHandler,
        fastConcurrency: Int = 2
    ) -> JobQueue {
        let handlers = JobHandlers(
            ingest: HandlerAdapter(recorder),
            render: HandlerAdapter(recorder),
            renderStep: HandlerAdapter(recorder),
            rescan: HandlerAdapter(recorder),
            extractZip: HandlerAdapter(recorder)
        )
        return JobQueue(writer: db.writer, handlers: handlers, fastConcurrency: fastConcurrency, slowConcurrency: 1)
    }

    private func fetchJob(_ db: SQLiteSpoolDatabase, id: Int64) async throws -> Job? {
        try await db.writer.read { conn in try Job.fetchOne(conn, id: id) }
    }

    @Test func enqueuedJobIsClaimedAndMarkedDone() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let recorder = RecordingHandler()
        let queue = makeQueue(db: db, recorder: recorder)

        await queue.start()
        let job = try await queue.enqueue(jobType: .ingest)

        try await waitUntil { await recorder.handledIds.contains(job.id!) }

        let stored = try await fetchJob(db, id: job.id!)
        #expect(stored?.status == .done)
        await queue.stop()
    }

    @Test func failingHandlerMarksJobFailedWithError() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let recorder = RecordingHandler()
        await recorder.setShouldFail(true)
        let queue = makeQueue(db: db, recorder: recorder)

        await queue.start()
        let job = try await queue.enqueue(jobType: .render)

        try await waitUntil {
            let stored = try await fetchJob(db, id: job.id!)
            return stored?.status == .failed
        }
        let stored = try await fetchJob(db, id: job.id!)
        #expect(stored?.error != nil)
        await queue.stop()
    }

    @Test func orphanedRunningJobIsRequeuedOnStart() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let job = try await db.writer.write { conn in
            try Job(jobType: .render, status: .running).inserted(conn)
        }

        let recorder = RecordingHandler()
        let queue = makeQueue(db: db, recorder: recorder)
        await queue.start()

        try await waitUntil { await recorder.handledIds.contains(job.id!) }
        await queue.stop()
    }

    @Test func slowLaneJobDoesNotBlockFastLaneJob() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let gate = Gate()
        let handlers = JobHandlers(
            ingest: FastHandler(),
            render: FastHandler(),
            renderStep: BlockingHandler(gate: gate),
            rescan: FastHandler(),
            extractZip: FastHandler()
        )
        let queue = JobQueue(writer: db.writer, handlers: handlers, fastConcurrency: 1, slowConcurrency: 1)
        await queue.start()

        let slowJob = try await queue.enqueue(jobType: .renderStep)
        try await waitUntil { await gate.isBlocking }

        let fastJob = try await queue.enqueue(jobType: .ingest)
        try await waitUntil {
            let stored = try await fetchJob(db, id: fastJob.id!)
            return stored?.status == .done
        }

        let slowStored = try await fetchJob(db, id: slowJob.id!)
        #expect(slowStored?.status == .running)

        await gate.release()
        try await waitUntil {
            let stored = try await fetchJob(db, id: slowJob.id!)
            return stored?.status == .done
        }
        await queue.stop()
    }
}

private struct HandlerAdapter: JobHandler {
    let recorder: RecordingHandler
    init(_ recorder: RecordingHandler) { self.recorder = recorder }
    func handle(_ job: Job) async throws { try await recorder.handle(job) }
}

private extension RecordingHandler {
    func setShouldFail(_ value: Bool) { shouldFail = value }
}

private struct FastHandler: JobHandler {
    func handle(_ job: Job) async throws {}
}

private actor Gate {
    private(set) var isBlocking = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        isBlocking = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct BlockingHandler: JobHandler {
    let gate: Gate
    func handle(_ job: Job) async throws {
        await gate.waitForRelease()
    }
}

/// Small polling helper — the job queue is deliberately event-driven (nudge-based), not
/// synchronously testable, so tests wait for the async side effect to land rather than
/// asserting immediately after enqueue.
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within \(timeout)")
}
