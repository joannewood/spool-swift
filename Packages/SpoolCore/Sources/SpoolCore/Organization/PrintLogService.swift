import Foundation
import GRDB

/// Deliberately a separate table/service from `PrintMetadataService` — see
/// `PrintLog`'s own doc comment: marking a file printed must never touch
/// `print_metadata.source`, which would silently block future auto-extraction.
public struct PrintLogService: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func upsert(fileId: Int64, printed: Bool, rating: Int?, comments: String?) async throws {
        try await writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO print_log (file_id, printed, rating, comments)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET
                    printed = excluded.printed, rating = excluded.rating, comments = excluded.comments
                """, arguments: [fileId, printed, rating, comments])
        }
    }

    public func fetch(fileId: Int64) async throws -> PrintLog? {
        try await writer.read { conn in try PrintLog.fetchOne(conn, key: fileId) }
    }
}
