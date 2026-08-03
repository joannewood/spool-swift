import Foundation
import GRDB

/// Wraps a `Codable` value so it round-trips through a SQLite `TEXT` column as JSON —
/// used for `print_metadata.settings_json` and `app_settings`' structured fields, the
/// same role Postgres's `jsonb` columns play in the source schema.
public struct JSONColumn<Value: Codable & Sendable>: Codable, DatabaseValueConvertible, Sendable {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public var databaseValue: DatabaseValue {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return DatabaseValue.null
        }
        return string.databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> JSONColumn<Value>? {
        guard let string = String.fromDatabaseValue(dbValue),
              let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(Value.self, from: data) else {
            return nil
        }
        return JSONColumn(value)
    }
}
