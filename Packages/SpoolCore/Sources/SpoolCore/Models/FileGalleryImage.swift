import Foundation
import GRDB

/// One slide in a file's thumbnail gallery — see `GalleryImageKind` for what the three
/// kinds mean. `sourcePath` is the original photo's path on disk (nil for `rendered`,
/// which has no source file of its own); `label` is the display filename for a photo
/// slide (nil for `rendered`, whose label is derived from its kind in the UI instead).
public struct FileGalleryImage: SpoolIdentifiableRecord, Sendable {
    public static let databaseTableName = "file_gallery_images"

    public var id: Int64?
    public var fileId: Int64
    public var kind: GalleryImageKind
    public var thumbnailPath: String
    public var sourcePath: String?
    public var label: String?
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        fileId: Int64,
        kind: GalleryImageKind,
        thumbnailPath: String,
        sourcePath: String? = nil,
        label: String? = nil,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fileId = fileId
        self.kind = kind
        self.thumbnailPath = thumbnailPath
        self.sourcePath = sourcePath
        self.label = label
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}
