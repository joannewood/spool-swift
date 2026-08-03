import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct JobQueueStatusServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp", label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    private func makeFile(_ db: SQLiteSpoolDatabase, rootId: Int64, filename: String) async throws -> Int64 {
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: rootId, path: "/tmp/\(filename)", filename: filename, ext: "stl", sizeBytes: 1).inserted(conn)
        }
        return file.id!
    }

    @Test func queueSummaryOnlyCountsQueuedAndRunning() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, filename: "a.stl")
        try await db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO jobs (file_id, job_type, status, created_at) VALUES (?, 'render', 'queued', datetime('now'))", arguments: [fileId])
            try conn.execute(sql: "INSERT INTO jobs (file_id, job_type, status, created_at) VALUES (?, 'render', 'done', datetime('now'))", arguments: [fileId])
        }

        let service = JobQueueStatusService(writer: db.writer)
        let summary = try await service.queueSummary()

        #expect(summary.count == 1)
        #expect(summary.first?.jobType == .render)
        #expect(summary.first?.status == .queued)
        #expect(summary.first?.count == 1)
    }

    @Test func runningJobsIncludesTargetName() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, filename: "widget.stl")
        try await db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO jobs (file_id, job_type, status, created_at) VALUES (?, 'ingest', 'running', datetime('now'))", arguments: [fileId])
        }

        let service = JobQueueStatusService(writer: db.writer)
        let running = try await service.runningJobs()

        #expect(running.count == 1)
        #expect(running.first?.targetName == "widget.stl")
        #expect(running.first?.jobType == .ingest)
    }

    @Test func recentActivityOnlyShowsDoneAndFailedNewestFirst() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, filename: "a.stl")
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO jobs (file_id, job_type, status, created_at, completed_at) VALUES (?, 'render', 'done', datetime('now'), datetime('now', '-2 seconds'))",
                arguments: [fileId]
            )
            try conn.execute(
                sql: "INSERT INTO jobs (file_id, job_type, status, error, created_at, completed_at) VALUES (?, 'render_step', 'failed', 'boom', datetime('now'), datetime('now', '-1 seconds'))",
                arguments: [fileId]
            )
            try conn.execute(sql: "INSERT INTO jobs (file_id, job_type, status, created_at) VALUES (?, 'render', 'queued', datetime('now'))", arguments: [fileId])
        }

        let service = JobQueueStatusService(writer: db.writer)
        let activity = try await service.recentActivity()

        #expect(activity.count == 2, "the still-queued job must not appear")
        #expect(activity.first?.status == .failed, "newest completed_at first")
        #expect(activity.first?.error == "boom")
    }

    @Test func ingestionTotalsCountsByStatus() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let doneId = try await makeFile(db, rootId: rootId, filename: "done.stl")
        _ = try await makeFile(db, rootId: rootId, filename: "pending.stl")
        try await db.writer.write { conn in
            try conn.execute(sql: "UPDATE files SET render_status = 'done', content_hash = 'h' WHERE id = ?", arguments: [doneId])
        }

        let service = JobQueueStatusService(writer: db.writer)
        let totals = try await service.ingestionTotals()

        #expect(totals.totalFiles == 2)
        #expect(totals.renderDone == 1)
        #expect(totals.renderPending == 1)
        #expect(totals.unhashed == 1)
    }
}
