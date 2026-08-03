import Foundation
import GRDB

/// One of the three watched folders (drop folder / library / downloads). Unlike the
/// source app, there is no `container_path` — that was a Docker bind-mount artifact.
/// Filesystem access instead flows through `bookmarkData`, a security-scoped bookmark
/// captured when the user grants the folder via `NSOpenPanel`.
public struct WatchedRoot: SpoolIdentifiableRecord, Sendable {
    public static let databaseTableName = "watched_roots"

    public var id: Int64?
    public var hostPath: String
    public var label: String
    public var kind: RootKind
    public var ingestMode: RootIngestMode
    public var active: Bool
    public var lastScannedAt: Date?
    public var bookmarkData: Data

    public init(
        id: Int64? = nil,
        hostPath: String,
        label: String,
        kind: RootKind,
        ingestMode: RootIngestMode = .indexInPlace,
        active: Bool = true,
        lastScannedAt: Date? = nil,
        bookmarkData: Data
    ) {
        self.id = id
        self.hostPath = hostPath
        self.label = label
        self.kind = kind
        self.ingestMode = ingestMode
        self.active = active
        self.lastScannedAt = lastScannedAt
        self.bookmarkData = bookmarkData
    }
}
