import GRDB

/// Shared conformance for every table record: maps Swift's camelCase properties to the
/// schema's snake_case columns automatically, so model structs don't need hand-written
/// `CodingKeys`.
public protocol SpoolRecord: Codable, FetchableRecord, MutablePersistableRecord {}

public extension SpoolRecord {
    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
}

/// A record with an autoincrement `INTEGER PRIMARY KEY` id, assigned by SQLite on insert.
public protocol SpoolIdentifiableRecord: SpoolRecord, Identifiable {
    var id: Int64? { get set }
}

public extension SpoolIdentifiableRecord {
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
