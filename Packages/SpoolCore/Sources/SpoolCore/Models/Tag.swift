import GRDB

public struct Tag: SpoolIdentifiableRecord, Sendable {
    public static let databaseTableName = "tags"

    public var id: Int64?
    public var name: String

    public init(id: Int64? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

/// Composite-PK join table (file_id, tag_id) — no surrogate id, so it conforms to
/// `SpoolRecord` directly rather than `SpoolIdentifiableRecord`.
public struct FileTag: SpoolRecord, Sendable {
    public static let databaseTableName = "file_tags"

    public var fileId: Int64
    public var tagId: Int64

    public init(fileId: Int64, tagId: Int64) {
        self.fileId = fileId
        self.tagId = tagId
    }
}
