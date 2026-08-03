import Foundation
import GRDB

/// A nestable project. `sourceFolderPath` is set only for projects created by the
/// folder-grouping auto-suggestion heuristic (matched/deduped by path, not name, so a
/// rename doesn't orphan future matches); a manually-created project leaves it `nil`
/// and is never a match candidate for auto-suggestion.
public struct Project: SpoolIdentifiableRecord, Sendable {
    public static let databaseTableName = "projects"

    public var id: Int64?
    public var name: String
    public var description: String?
    public var parentProjectId: Int64?
    public var createdAt: Date
    public var sourceFolderPath: String?
    public var color: ProjectColor

    public init(
        id: Int64? = nil,
        name: String,
        description: String? = nil,
        parentProjectId: Int64? = nil,
        createdAt: Date = Date(),
        sourceFolderPath: String? = nil,
        color: ProjectColor = .blue
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parentProjectId = parentProjectId
        self.createdAt = createdAt
        self.sourceFolderPath = sourceFolderPath
        self.color = color
    }
}

/// Composite-PK join table (project_id, file_id) with a suggestion-review status.
public struct ProjectFile: SpoolRecord, Sendable {
    public static let databaseTableName = "project_files"

    public var projectId: Int64
    public var fileId: Int64
    public var status: SuggestionStatus

    public init(projectId: Int64, fileId: Int64, status: SuggestionStatus = .confirmed) {
        self.projectId = projectId
        self.fileId = fileId
        self.status = status
    }
}
