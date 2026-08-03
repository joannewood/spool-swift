import Foundation
import GRDB

/// A confirmed or auto-suggested link between two files. Auto-suggestion always inserts
/// with `status = .suggested` via insert-or-ignore against the (from, to, type) unique
/// index, so a user's manual confirm/reject is never overwritten by a later rescan.
public struct Relationship: SpoolIdentifiableRecord, Sendable {
    public static let databaseTableName = "relationships"

    public var id: Int64?
    public var fromFileId: Int64
    public var toFileId: Int64
    public var type: RelationshipType
    public var status: SuggestionStatus
    public var confidence: Double?
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        fromFileId: Int64,
        toFileId: Int64,
        type: RelationshipType,
        status: SuggestionStatus = .suggested,
        confidence: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.fromFileId = fromFileId
        self.toFileId = toFileId
        self.type = type
        self.status = status
        self.confidence = confidence
        self.createdAt = createdAt
    }
}
