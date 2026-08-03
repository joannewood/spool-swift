import Foundation
import GRDB

/// Thin protocol over a GRDB `DatabaseWriter` so job handlers / ingestion code depend
/// on an abstraction, not a concrete SQLite file — makes it easy to swap in an
/// in-memory database for tests.
public protocol SpoolDatabase: Sendable {
    var writer: any DatabaseWriter { get }
}

public final class SQLiteSpoolDatabase: SpoolDatabase, Sendable {
    public let writer: any DatabaseWriter

    /// - Parameter path: pass `nil` for an in-memory database (tests); pass a real path
    ///   for the app's on-disk library (see `SpoolDatabase.defaultPath`).
    public init(path: String?) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            db.add(function: Self.normalizeFunction)
        }
        if let path {
            self.writer = try DatabasePool(path: path, configuration: config)
        } else {
            self.writer = try DatabaseQueue(configuration: config)
        }
        try Self.migrator.migrate(writer)
    }

    private static let normalizeFunction = DatabaseFunction(
        "normalize", argumentCount: 1, pure: true
    ) { values in
        guard let text = String.fromDatabaseValue(values[0]) else { return nil }
        return SpoolTextNormalization.normalize(text)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerMigrations(&migrator)
        return migrator
    }

    /// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/spool.sqlite`
    /// under App Sandbox — `Application Support` inside the container is the standard
    /// sandboxed-app location, and needs no extra entitlement beyond the sandbox itself.
    public static func defaultPath() throws -> String {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return supportDir.appendingPathComponent("spool.sqlite").path
    }
}
