import Foundation
import GRDB

/// Singleton settings row (`id` is always 1, enforced by a `CHECK` in Migrations).
/// `rescanIntervalSeconds` has a 30s floor enforced at the write layer, not the schema,
/// matching the source app's `MIN_RESCAN_INTERVAL_SECONDS` guard.
public struct AppSettings: SpoolRecord, Sendable {
    public static let databaseTableName = "app_settings"

    public var id: Int64
    public var rescanEnabled: Bool
    public var rescanIntervalSeconds: Int
    public var updatedAt: Date
    public var autoAcceptArchives: Bool
    /// Security-scoped bookmark for an optional, user-located `unar`/`7z` binary — see
    /// the `v4_archive_tool_bookmark` migration for why this exists at all. `nil` means
    /// "not configured," which is a fully supported state: .7z/.rar archives just show
    /// as unsupported, same as before this existed.
    public var archiveToolBookmarkData: Data?

    public static let singletonId: Int64 = 1
    public static let minRescanIntervalSeconds = 30
    public static let defaultRescanIntervalSeconds = 300

    public init(
        id: Int64 = AppSettings.singletonId,
        rescanEnabled: Bool = true,
        rescanIntervalSeconds: Int = AppSettings.defaultRescanIntervalSeconds,
        updatedAt: Date = Date(),
        autoAcceptArchives: Bool = false,
        archiveToolBookmarkData: Data? = nil
    ) {
        self.id = id
        self.rescanEnabled = rescanEnabled
        self.rescanIntervalSeconds = rescanIntervalSeconds
        self.updatedAt = updatedAt
        self.autoAcceptArchives = autoAcceptArchives
        self.archiveToolBookmarkData = archiveToolBookmarkData
    }
}
