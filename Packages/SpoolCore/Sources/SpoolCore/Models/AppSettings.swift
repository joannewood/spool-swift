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

    public static let singletonId: Int64 = 1
    public static let minRescanIntervalSeconds = 30
    public static let defaultRescanIntervalSeconds = 300

    public init(
        id: Int64 = AppSettings.singletonId,
        rescanEnabled: Bool = true,
        rescanIntervalSeconds: Int = AppSettings.defaultRescanIntervalSeconds,
        updatedAt: Date = Date(),
        autoAcceptArchives: Bool = false
    ) {
        self.id = id
        self.rescanEnabled = rescanEnabled
        self.rescanIntervalSeconds = rescanIntervalSeconds
        self.updatedAt = updatedAt
        self.autoAcceptArchives = autoAcceptArchives
    }
}
