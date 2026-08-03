import GRDB

/// An archive found on disk that's worth reviewing (namelist peek found a recognized
/// model extension inside, no decompression yet). Uniqueness is on (path, content_hash)
/// — not path alone — so a rejected archive at a reused filename (e.g. "Archive.zip"
/// downloaded again with different content) gets asked about fresh.
public struct ZipFile: SpoolIdentifiableRecord, Sendable {
    public static let databaseTableName = "zip_files"

    public var id: Int64?
    public var watchedRootId: Int64
    public var path: String
    public var filename: String
    public var sizeBytes: Int64
    public var status: ZipStatus
    public var error: String?
    public var contentHash: String?

    public init(
        id: Int64? = nil,
        watchedRootId: Int64,
        path: String,
        filename: String,
        sizeBytes: Int64,
        status: ZipStatus = .suggested,
        error: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.watchedRootId = watchedRootId
        self.path = path
        self.filename = filename
        self.sizeBytes = sizeBytes
        self.status = status
        self.error = error
        self.contentHash = contentHash
    }
}
