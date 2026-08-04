import Foundation
import GRDB

/// The singleton `app_settings` row — rescan cadence/pause and the archive
/// auto-accept toggle.
public struct AppSettingsService: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func get() async throws -> AppSettings {
        try await writer.read { conn in
            // The migration seeds this row unconditionally, so it always exists —
            // falling back to the type's own defaults is defense-in-depth, not an
            // expected path.
            try AppSettings.fetchOne(conn, key: AppSettings.singletonId) ?? AppSettings()
        }
    }

    /// `intervalSeconds` is floored at `AppSettings.minRescanIntervalSeconds` so a
    /// typo/aggressive value typed into the settings form can't turn the rescan loop
    /// into a tight poll.
    public func updateRescan(enabled: Bool, intervalSeconds: Int) async throws {
        let flooredInterval = max(intervalSeconds, AppSettings.minRescanIntervalSeconds)
        try await writer.write { conn in
            try conn.execute(
                sql: """
                    UPDATE app_settings
                    SET rescan_enabled = ?, rescan_interval_seconds = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [enabled, flooredInterval, Date(), AppSettings.singletonId]
            )
        }
    }

    public func updateAutoAcceptArchives(_ enabled: Bool) async throws {
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE app_settings SET auto_accept_archives = ?, updated_at = ? WHERE id = ?",
                arguments: [enabled, Date(), AppSettings.singletonId]
            )
        }
    }
}
