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

        // Poll the terminal DB state directly rather than "handled" then an
        // un-retried status check — the handler recording its own id and the job
        // row being marked done are two separate async hops, not one atomic step.
        try await waitUntil {
            let stored = try await fetchJob(db, id: job.id!)
            return stored?.status == .done
        }
        #expect(await recorder.handledIds.contains(job.id!))
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

    /// Confirmed live as a real bug: a STEP-tessellation handler that never returned
    /// (a Swift-side hang downstream of the converter process, not the converter
    /// itself) permanently froze the single-concurrency slow lane — every job queued
    /// behind it sat forever, since `inFlight` never dropped back below `concurrency`.
    @Test func hungHandlerTimesOutAndDoesNotBlockTheLane() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        // Two separate gates (not one reused) — a handler call that loses the timeout
        // race is abandoned, not cancelled, so its own `waitForRelease()` continuation
        // is still out there and needs its own release to avoid leaking it.
        let gate1 = Gate()
        let gate2 = Gate()
        let handler = SequentialGateHandler(gates: [gate1, gate2])
        let handlers = JobHandlers(
            ingest: FastHandler(),
            render: FastHandler(),
            renderStep: handler,
            rescan: FastHandler(),
            extractZip: FastHandler()
        )
        let queue = JobQueue(
            writer: db.writer, handlers: handlers, fastConcurrency: 1, slowConcurrency: 1,
            handlerTimeoutSeconds: 0.05
        )
        await queue.start()

        let hungJob = try await queue.enqueue(jobType: .renderStep)
        try await waitUntil { await gate1.isBlocking }
        try await waitUntil {
            let stored = try await fetchJob(db, id: hungJob.id!)
            return stored?.status == .failed
        }
        let hungStored = try await fetchJob(db, id: hungJob.id!)
        #expect(hungStored?.error?.contains("did not finish within") == true)

        // the lane recovered and can claim a second job even though the first
        // handler call is (as far as the lane is concerned) still out there blocked
        // on gate1
        let nextJob = try await queue.enqueue(jobType: .renderStep)
        try await waitUntil { await gate2.isBlocking }
        try await waitUntil {
            let stored = try await fetchJob(db, id: nextJob.id!)
            return stored?.status == .failed
        }

        await gate1.release()
        await gate2.release()
        await queue.stop()
    }
}

/// Blocks on a different gate each call — lets a test drive two independent
/// never-released waits (one per abandoned handler invocation) without either one
/// leaking its continuation when the test cleans up.
private actor SequentialGateHandler: JobHandler {
    private let gates: [Gate]
    private var index = 0
    init(gates: [Gate]) { self.gates = gates }
    func handle(_ job: Job) async throws {
        let gate = gates[min(index, gates.count - 1)]
        index += 1
        await gate.waitForRelease()
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
