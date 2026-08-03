import Foundation
import GRDB

/// Tags are free-form and shared across files (`tags.name UNIQUE`) — adding "PLA" to a
/// second file reuses the same tag row rather than creating a duplicate.
public struct TagService: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    @discardableResult
    public func addTag(named rawName: String, toFileId fileId: Int64) async throws -> Tag? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        return try await writer.write { conn in
            let tag: Tag
            if let existing = try Tag.filter(Column("name") == name).fetchOne(conn) {
                tag = existing
            } else {
                tag = try Tag(name: name).inserted(conn)
            }
            try conn.execute(
                sql: "INSERT INTO file_tags (file_id, tag_id) VALUES (?, ?) ON CONFLICT DO NOTHING",
                arguments: [fileId, tag.id]
            )
            return tag
        }
    }

    public func removeTag(tagId: Int64, fromFileId fileId: Int64) async throws {
        try await writer.write { conn in
            try conn.execute(
                sql: "DELETE FROM file_tags WHERE file_id = ? AND tag_id = ?",
                arguments: [fileId, tagId]
            )
        }
    }

    public func tags(forFileId fileId: Int64) async throws -> [Tag] {
        try await writer.read { conn in
            try Tag
                .filter(sql: "id IN (SELECT tag_id FROM file_tags WHERE file_id = ?)", arguments: [fileId])
                .order(Column("name"))
                .fetchAll(conn)
        }
    }

    public func allTags() async throws -> [Tag] {
        try await writer.read { conn in try Tag.order(Column("name")).fetchAll(conn) }
    }
}
