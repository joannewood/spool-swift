import Foundation
import GRDB

public struct JobQueueCount: Sendable, Identifiable {
    public let jobType: JobType
    public let status: JobStatus
    public let count: Int
    public var id: String { "\(jobType.rawValue)-\(status.rawValue)" }
}

public struct RunningJobInfo: Sendable, Identifiable {
    public let id: Int64
    public let jobType: JobType
    public let createdAt: Date
    public let targetName: String?
}

public struct RecentJobActivity: Sendable, Identifiable {
    public let id: Int64
    public let jobType: JobType
    public let status: JobStatus
    public let error: String?
    public let completedAt: Date?
    public let targetName: String?
}

public struct IngestionTotals: Sendable {
    public let totalFiles: Int
    public let unhashed: Int
    public let renderPending: Int
    public let renderDone: Int
    public let renderFailed: Int

    public static let zero = IngestionTotals(totalFiles: 0, unhashed: 0, renderPending: 0, renderDone: 0, renderFailed: 0)
}

/// Read-only view into the job queue and ingestion pipeline for the admin status page —
/// the native equivalent of the source app's `/admin/status` dashboard (job_type ×
/// status counts, currently-running jobs, recent done/failed activity, library-wide
/// hash/render totals).
public struct JobQueueStatusService: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// job_type × status counts for the two *live* statuses only (queued, running) —
    /// `jobs` rows are never deleted once done/failed, so a done/failed count here
    /// would be an ever-growing lifetime total, not a snapshot of current queue state.
    /// `recentActivity` is the right place to look at done/failed jobs.
    public func queueSummary() async throws -> [JobQueueCount] {
        try await writer.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT job_type, status, COUNT(*) AS n FROM jobs
                WHERE status IN ('queued', 'running')
                GROUP BY job_type, status
                ORDER BY job_type, status
                """)
            return rows.compactMap { row -> JobQueueCount? in
                guard let jobType = JobType(rawValue: row["job_type"]), let status = JobStatus(rawValue: row["status"])
                else { return nil }
                return JobQueueCount(jobType: jobType, status: status, count: row["n"])
            }
        }
    }

    /// Job(s) currently claimed — normally 0/1 per lane, but not assumed to be exactly
    /// one: a job orphaned by a crash sits at `running` until the next startup's
    /// requeue, so more than one showing here (or one stuck a long time) is itself a
    /// useful signal.
    public func runningJobs() async throws -> [RunningJobInfo] {
        try await writer.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT j.id AS id, j.job_type AS job_type, j.created_at AS created_at,
                       COALESCE(f.filename, z.filename) AS target_name
                FROM jobs j
                LEFT JOIN files f ON f.id = j.file_id
                LEFT JOIN zip_files z ON z.id = j.zip_file_id
                WHERE j.status = 'running'
                ORDER BY j.created_at
                """)
            return rows.compactMap { row -> RunningJobInfo? in
                guard let jobType = JobType(rawValue: row["job_type"]) else { return nil }
                return RunningJobInfo(id: row["id"], jobType: jobType, createdAt: row["created_at"], targetName: row["target_name"])
            }
        }
    }

    /// Most recently finished jobs (done or failed), newest first, with a human-
    /// readable target name and the raw error text for failures — the live
    /// "what just happened" feed.
    public func recentActivity(limit: Int = 50) async throws -> [RecentJobActivity] {
        try await writer.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT j.id AS id, j.job_type AS job_type, j.status AS status, j.error AS error, j.completed_at AS completed_at,
                       COALESCE(f.filename, z.filename) AS target_name
                FROM jobs j
                LEFT JOIN files f ON f.id = j.file_id
                LEFT JOIN zip_files z ON z.id = j.zip_file_id
                WHERE j.status IN ('done', 'failed')
                ORDER BY j.completed_at DESC, j.id DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.compactMap { row -> RecentJobActivity? in
                guard let jobType = JobType(rawValue: row["job_type"]), let status = JobStatus(rawValue: row["status"])
                else { return nil }
                return RecentJobActivity(
                    id: row["id"], jobType: jobType, status: status, error: row["error"],
                    completedAt: row["completed_at"], targetName: row["target_name"]
                )
            }
        }
    }

    /// Library-wide counts across the hash/render pipeline.
    public func ingestionTotals() async throws -> IngestionTotals {
        try await writer.read { conn in
            guard let row = try Row.fetchOne(conn, sql: """
                SELECT
                    COUNT(*) AS total_files,
                    SUM(CASE WHEN content_hash IS NULL THEN 1 ELSE 0 END) AS unhashed,
                    SUM(CASE WHEN render_status = 'pending' THEN 1 ELSE 0 END) AS render_pending,
                    SUM(CASE WHEN render_status = 'done' THEN 1 ELSE 0 END) AS render_done,
                    SUM(CASE WHEN render_status = 'failed' THEN 1 ELSE 0 END) AS render_failed
                FROM files WHERE status = 'active'
                """) else { return .zero }
            return IngestionTotals(
                totalFiles: row["total_files"],
                unhashed: (row["unhashed"] as Int?) ?? 0,
                renderPending: (row["render_pending"] as Int?) ?? 0,
                renderDone: (row["render_done"] as Int?) ?? 0,
                renderFailed: (row["render_failed"] as Int?) ?? 0
            )
        }
    }
}
