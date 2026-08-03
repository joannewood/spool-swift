import Foundation
import GRDB

/// Confirm/reject actions for both suggestion heuristics (`RelationshipSuggestionService`,
/// `ProjectSuggestionService`) — a thin layer over the same `status` column each of
/// those already writes `'suggested'` into.
public struct SuggestionReviewService: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Directly creates a confirmed relationship — the manual "add relationship" flow
    /// in the file detail UI, as opposed to `RelationshipSuggestionService`'s heuristic
    /// inserts (which always start at `'suggested'`). Same insert-or-ignore-on-
    /// (from, to, type) guard, so picking a pair/type that already exists as a
    /// suggestion just confirms it instead of erroring.
    public func createRelationship(fromFileId: Int64, toFileId: Int64, type: RelationshipType) async throws {
        try await writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO relationships (from_file_id, to_file_id, type, status, created_at)
                VALUES (?, ?, ?, 'confirmed', ?)
                ON CONFLICT (from_file_id, to_file_id, type) DO UPDATE SET status = 'confirmed'
                """, arguments: [fromFileId, toFileId, type.rawValue, Date()])
        }
    }

    /// Deletes a relationship outright, confirmed or suggested — the "remove" action on
    /// an already-confirmed link, as opposed to `rejectRelationship` which keeps the
    /// row around (as `status = 'rejected'`) specifically so a heuristic re-run won't
    /// re-suggest it. A confirmed relationship was a deliberate user action with no
    /// heuristic to guard against re-suggesting, so there's nothing worth keeping a
    /// tombstone row for.
    public func removeRelationship(id: Int64) async throws {
        try await writer.write { conn in
            try conn.execute(sql: "DELETE FROM relationships WHERE id = ?", arguments: [id])
        }
    }

    public func suggestedRelationships() async throws -> [Relationship] {
        try await writer.read { conn in
            try Relationship.filter(Column("status") == SuggestionStatus.suggested.rawValue).fetchAll(conn)
        }
    }

    public func confirmRelationship(id: Int64) async throws {
        try await setRelationshipStatus(id: id, status: .confirmed)
    }

    public func rejectRelationship(id: Int64) async throws {
        try await setRelationshipStatus(id: id, status: .rejected)
    }

    private func setRelationshipStatus(id: Int64, status: SuggestionStatus) async throws {
        try await writer.write { conn in
            try conn.execute(sql: "UPDATE relationships SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    /// Confirms just the given subset — the "Confirm Selected" bulk action, for a
    /// checked-off subset of the review queue, as opposed to `confirmAllSuggestedRelationships`'
    /// unconditional sweep of everything.
    public func confirmRelationships(ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await writer.write { conn in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            try conn.execute(
                sql: "UPDATE relationships SET status = 'confirmed' WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
        }
    }

    /// Confirms every currently-suggested relationship in one action — deliberately
    /// takes no ids from the client at all (the same "runs as one server-side
    /// action, not a page-by-page selection" reasoning the source app's own accept-all
    /// routes document): rendering a checkbox and hidden field for every row of a
    /// genuinely large suggestion queue is real client-side work for no benefit when
    /// the intent is just "yes, all of them."
    @discardableResult
    public func confirmAllSuggestedRelationships() async throws -> Int {
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE relationships SET status = 'confirmed' WHERE status = 'suggested'"
            )
            return conn.changesCount
        }
    }

    public func suggestedProjectMemberships() async throws -> [ProjectFile] {
        try await writer.read { conn in
            try ProjectFile.filter(Column("status") == SuggestionStatus.suggested.rawValue).fetchAll(conn)
        }
    }

    public func confirmProjectMembership(projectId: Int64, fileId: Int64) async throws {
        try await setProjectMembershipStatus(projectId: projectId, fileId: fileId, status: .confirmed)
    }

    public func rejectProjectMembership(projectId: Int64, fileId: Int64) async throws {
        try await setProjectMembershipStatus(projectId: projectId, fileId: fileId, status: .rejected)
    }

    private func setProjectMembershipStatus(projectId: Int64, fileId: Int64, status: SuggestionStatus) async throws {
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE project_files SET status = ? WHERE project_id = ? AND file_id = ?",
                arguments: [status.rawValue, projectId, fileId]
            )
        }
    }

    /// Confirms just the given (project, file) pairs — the "Confirm Selected" bulk
    /// action for a checked-off subset of the review queue.
    public func confirmProjectMemberships(_ pairs: [(projectId: Int64, fileId: Int64)]) async throws {
        guard !pairs.isEmpty else { return }
        try await writer.write { conn in
            for pair in pairs {
                try conn.execute(
                    sql: "UPDATE project_files SET status = 'confirmed' WHERE project_id = ? AND file_id = ?",
                    arguments: [pair.projectId, pair.fileId]
                )
            }
        }
    }

    /// Confirms every currently-suggested project membership in one server-side
    /// action — same "no per-row id list from the client" reasoning as
    /// `confirmAllSuggestedRelationships`.
    @discardableResult
    public func confirmAllSuggestedProjectMemberships() async throws -> Int {
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE project_files SET status = 'confirmed' WHERE status = 'suggested'"
            )
            return conn.changesCount
        }
    }
}
