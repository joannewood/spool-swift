import Foundation
import GRDB

/// A non-model file living alongside model files in a project folder (README, preview
/// photo) — indexed for presence only, no hash/render, surfaced on the owning project's
/// page only, never the main library grid.
public struct SidecarFile: SpoolIdentifiableRecord, Sendable {
    public static let databaseTableName = "sidecar_files"

    public var id: Int64?
    public var watchedRootId: Int64
    public var path: String
    public var filename: String
    public var ext: String
    public var sizeBytes: Int64
    public var firstSeenAt: Date
    public var thumbnailPath: String?
    public var status: SidecarStatus

    public init(
        id: Int64? = nil,
        watchedRootId: Int64,
        path: String,
        filename: String,
        ext: String,
        sizeBytes: Int64,
        firstSeenAt: Date = Date(),
        thumbnailPath: String? = nil,
        status: SidecarStatus = .active
    ) {
        self.id = id
        self.watchedRootId = watchedRootId
        self.path = path
        self.filename = filename
        self.ext = ext
        self.sizeBytes = sizeBytes
        self.firstSeenAt = firstSeenAt
        self.thumbnailPath = thumbnailPath
        self.status = status
    }
}
