import Foundation
import GRDB

/// A model file (.stl/.3mf/.step/.stp/.svg/.scad/.gcode/.obj) discovered under a
/// watched root. `contentHash` is nullable — a live-watched file is staged before it's
/// hashed, matching the source app's ingest→hash split. `filenameNormalized` /
/// `displayNameNormalized` are trigger-maintained (see Migrations) so search can treat
/// hyphens/underscores/spaces as equivalent without re-normalizing at query time.
public struct SpoolFile: SpoolIdentifiableRecord, Sendable {
    public static let databaseTableName = "files"

    public var id: Int64?
    public var watchedRootId: Int64
    public var path: String
    public var filename: String
    public var ext: String
    public var sizeBytes: Int64
    public var contentHash: String?
    public var bboxX: Double?
    public var bboxY: Double?
    public var bboxZ: Double?
    public var volumeMm3: Double?
    public var triCount: Int?
    public var isManifold: Bool?
    public var units: String?
    public var thumbnailPath: String?
    public var renderStatus: FileRenderStatus
    public var renderError: String?
    public var status: FileStatus
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var mtime: Date?
    public var displayName: String?

    public init(
        id: Int64? = nil,
        watchedRootId: Int64,
        path: String,
        filename: String,
        ext: String,
        sizeBytes: Int64,
        contentHash: String? = nil,
        bboxX: Double? = nil,
        bboxY: Double? = nil,
        bboxZ: Double? = nil,
        volumeMm3: Double? = nil,
        triCount: Int? = nil,
        isManifold: Bool? = nil,
        units: String? = nil,
        thumbnailPath: String? = nil,
        renderStatus: FileRenderStatus = .pending,
        renderError: String? = nil,
        status: FileStatus = .active,
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date(),
        mtime: Date? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.watchedRootId = watchedRootId
        self.path = path
        self.filename = filename
        self.ext = ext
        self.sizeBytes = sizeBytes
        self.contentHash = contentHash
        self.bboxX = bboxX
        self.bboxY = bboxY
        self.bboxZ = bboxZ
        self.volumeMm3 = volumeMm3
        self.triCount = triCount
        self.isManifold = isManifold
        self.units = units
        self.thumbnailPath = thumbnailPath
        self.renderStatus = renderStatus
        self.renderError = renderError
        self.status = status
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.mtime = mtime
        self.displayName = displayName
    }
}

/// Model-file extensions recognized by ingestion, mirroring the source app's
/// `MODEL_EXTENSIONS`. Kept here (not in an app target) so both the watcher and the
/// job handlers share one definition.
public enum ModelExtension: String, CaseIterable, Sendable {
    case stl, obj, svg, scad, gcode
    case threeMF = "3mf"
    case step, stp

    public static let all: Set<String> = Set(ModelExtension.allCases.map(\.rawValue))

    /// Fast lane (`render` job): mesh formats loadable without CAD tessellation.
    public static let fastRender: Set<String> = ["stl", "obj", "3mf", "svg", "gcode"]
    /// Slow lane (`render_step` job): needs B-rep tessellation.
    public static let stepFormats: Set<String> = ["step", "stp"]
    /// Deliberately no preview — see FileRenderStatus.unsupported.
    public static let noPreview: Set<String> = ["scad"]
}
