import Combine
import Foundation
import GRDB
import SpoolCore

@MainActor
final class FileDetailViewModel: ObservableObject {
    @Published private(set) var file: SpoolFile
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var printMetadata: PrintMetadata?
    @Published private(set) var printLog: PrintLog?
    @Published private(set) var confirmedRelationships: [(relationship: Relationship, otherFile: SpoolFile)] = []
    @Published private(set) var suggestedRelationships: [(relationship: Relationship, otherFile: SpoolFile)] = []
    @Published private(set) var confirmedProjects: [Project] = []
    @Published private(set) var suggestedProjects: [Project] = []
    @Published private(set) var allProjects: [Project] = []
    @Published var lastError: String?

    @Published var materialInput: String = ""
    @Published var printerProfileInput: String = ""
    @Published var slicerInput: String = ""
    @Published var notesInput: String = ""

    @Published var printedInput: Bool = false
    @Published var ratingInput: Int = 0
    @Published var commentsInput: String = ""
    private var savedPrinted = false
    private var savedRating = 0
    private var savedComments = ""

    /// Drives whether the print-log Save button shows at all — not just "is printed
    /// checked" (unchecking an already-saved-as-printed file needs a way to persist
    /// that too), but "does the current input differ from what's actually saved."
    var hasUnsavedPrintLogChanges: Bool {
        printedInput != savedPrinted || ratingInput != savedRating || commentsInput != savedComments
    }

    let detectedApps: [DetectedApp]
    private let environment: AppEnvironment

    init(file: SpoolFile, environment: AppEnvironment) {
        self.file = file
        self.environment = environment
        self.detectedApps = environment.detectedApps
    }

    func load() async {
        guard let fileId = file.id else { return }
        do {
            tags = try await environment.tags.tags(forFileId: fileId)
            printMetadata = try await fetchPrintMetadata(fileId: fileId)
            printLog = try await environment.printLog.fetch(fileId: fileId)
            allProjects = try await environment.projects.allProjects()
            materialInput = printMetadata?.material ?? ""
            printerProfileInput = printMetadata?.printerProfile ?? ""
            slicerInput = printMetadata?.slicer ?? ""
            notesInput = printMetadata?.notes ?? ""
            printedInput = printLog?.printed ?? false
            ratingInput = printLog?.rating ?? 0
            commentsInput = printLog?.comments ?? ""
            savedPrinted = printedInput
            savedRating = ratingInput
            savedComments = commentsInput
        } catch {
            lastError = "\(error)"
        }
        await loadRelationships()
        await loadProjectMemberships()
    }

    private func fetchPrintMetadata(fileId: Int64) async throws -> PrintMetadata? {
        try await environment.database.writer.read { conn in try PrintMetadata.fetchOne(conn, key: fileId) }
    }

    private func loadRelationships() async {
        guard let fileId = file.id else { return }
        do {
            let rows = try await environment.database.writer.read { conn -> [(Relationship, SpoolFile)] in
                let rels = try Relationship.fetchAll(
                    conn, sql: "SELECT * FROM relationships WHERE from_file_id = ? OR to_file_id = ?",
                    arguments: [fileId, fileId]
                )
                var pairs: [(Relationship, SpoolFile)] = []
                for rel in rels {
                    let otherId = rel.fromFileId == fileId ? rel.toFileId : rel.fromFileId
                    if let other = try SpoolFile.fetchOne(conn, id: otherId) {
                        pairs.append((rel, other))
                    }
                }
                return pairs
            }
            confirmedRelationships = rows.filter { $0.0.status == .confirmed }.map { ($0.0, $0.1) }
            suggestedRelationships = rows.filter { $0.0.status == .suggested }.map { ($0.0, $0.1) }
        } catch {
            lastError = "\(error)"
        }
    }

    private func loadProjectMemberships() async {
        guard let fileId = file.id else { return }
        do {
            let memberships = try await environment.projects.projectMemberships(forFileId: fileId)
            let byId = Dictionary(uniqueKeysWithValues: allProjects.compactMap { p in p.id.map { ($0, p) } })
            confirmedProjects = memberships.filter { $0.status == .confirmed }.compactMap { byId[$0.projectId] }
            suggestedProjects = memberships.filter { $0.status == .suggested }.compactMap { byId[$0.projectId] }
        } catch {
            lastError = "\(error)"
        }
    }

    func addTag(_ name: String) async {
        guard let fileId = file.id, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            _ = try await environment.tags.addTag(named: name, toFileId: fileId)
            tags = try await environment.tags.tags(forFileId: fileId)
        } catch { lastError = "\(error)" }
    }

    func removeTag(_ tag: Tag) async {
        guard let fileId = file.id, let tagId = tag.id else { return }
        do {
            try await environment.tags.removeTag(tagId: tagId, fromFileId: fileId)
            tags = try await environment.tags.tags(forFileId: fileId)
        } catch { lastError = "\(error)" }
    }

    func saveMetadataForm() async {
        guard let fileId = file.id else { return }
        do {
            try await environment.printMetadata.upsertManualEdit(
                fileId: fileId,
                material: materialInput.isEmpty ? nil : materialInput,
                printerProfile: printerProfileInput.isEmpty ? nil : printerProfileInput,
                slicer: slicerInput.isEmpty ? nil : slicerInput,
                notes: notesInput.isEmpty ? nil : notesInput
            )
            printMetadata = try await fetchPrintMetadata(fileId: fileId)
        } catch { lastError = "\(error)" }
    }

    func savePrintLog() async {
        guard let fileId = file.id else { return }
        do {
            try await environment.printLog.upsert(
                fileId: fileId, printed: printedInput,
                rating: ratingInput > 0 ? ratingInput : nil,
                comments: commentsInput.isEmpty ? nil : commentsInput
            )
            printLog = try await environment.printLog.fetch(fileId: fileId)
            savedPrinted = printedInput
            savedRating = ratingInput
            savedComments = commentsInput
        } catch { lastError = "\(error)" }
    }

    func addToProject(_ project: Project) async {
        guard let fileId = file.id, let projectId = project.id else { return }
        do {
            try await environment.projects.addFile(fileId: fileId, toProjectId: projectId)
            await loadProjectMemberships()
        } catch { lastError = "\(error)" }
    }

    func createAndAddToNewProject(name: String) async {
        guard let fileId = file.id, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let project = try await environment.projects.createProject(name: name)
            try await environment.projects.addFile(fileId: fileId, toProjectId: project.id!)
            allProjects = try await environment.projects.allProjects()
            await loadProjectMemberships()
        } catch { lastError = "\(error)" }
    }

    func removeFromProject(_ project: Project) async {
        guard let fileId = file.id, let projectId = project.id else { return }
        do {
            try await environment.projects.removeFile(fileId: fileId, fromProjectId: projectId)
            await loadProjectMemberships()
        } catch { lastError = "\(error)" }
    }

    func confirmRelationship(_ relationship: Relationship) async {
        guard let id = relationship.id else { return }
        do {
            try await environment.suggestionReview.confirmRelationship(id: id)
            await loadRelationships()
        } catch { lastError = "\(error)" }
    }

    func rejectRelationship(_ relationship: Relationship) async {
        guard let id = relationship.id else { return }
        do {
            try await environment.suggestionReview.rejectRelationship(id: id)
            await loadRelationships()
        } catch { lastError = "\(error)" }
    }

    func removeRelationship(_ relationship: Relationship) async {
        guard let id = relationship.id else { return }
        do {
            try await environment.suggestionReview.removeRelationship(id: id)
            await loadRelationships()
        } catch { lastError = "\(error)" }
    }

    func confirmProject(_ project: Project) async {
        guard let fileId = file.id, let projectId = project.id else { return }
        do {
            try await environment.suggestionReview.confirmProjectMembership(projectId: projectId, fileId: fileId)
            await loadProjectMemberships()
        } catch { lastError = "\(error)" }
    }

    func rejectProject(_ project: Project) async {
        guard let fileId = file.id, let projectId = project.id else { return }
        do {
            try await environment.suggestionReview.rejectProjectMembership(projectId: projectId, fileId: fileId)
            await loadProjectMemberships()
        } catch { lastError = "\(error)" }
    }

    func openInApp(_ app: DetectedApp) {
        OpenInAppService.open(fileURL: URL(fileURLWithPath: file.path), in: app)
    }

    /// A blank name clears the override, falling back to the real on-disk filename
    /// again — matches `FileService.setDisplayName`'s own trim-and-clear behavior.
    func rename(to newDisplayName: String) async {
        guard let fileId = file.id else { return }
        do {
            try await environment.files.setDisplayName(fileId: fileId, to: newDisplayName)
            let trimmed = newDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            file.displayName = trimmed.isEmpty ? nil : trimmed
        } catch { lastError = "\(error)" }
    }

    /// Backs the manual "add relationship" picker — a simple substring match over
    /// filename/display name, excluding this file itself. Not routed through
    /// `SearchService`'s relevance tiering; that's built for the main library search
    /// bar, and this just needs "find the other file quickly," capped to a small list.
    func searchFiles(query: String) async -> [SpoolFile] {
        guard let fileId = file.id else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        do {
            return try await environment.database.writer.read { conn in
                if trimmed.isEmpty {
                    return try SpoolFile.fetchAll(conn, sql: """
                        SELECT * FROM files WHERE status = 'active' AND id != ?
                        ORDER BY first_seen_at DESC LIMIT 30
                        """, arguments: [fileId])
                } else {
                    let pattern = "%\(trimmed)%"
                    return try SpoolFile.fetchAll(conn, sql: """
                        SELECT * FROM files WHERE status = 'active' AND id != ?
                          AND (filename LIKE ? OR display_name LIKE ?)
                        ORDER BY filename LIMIT 30
                        """, arguments: [fileId, pattern, pattern])
                }
            }
        } catch {
            lastError = "\(error)"
            return []
        }
    }

    func addRelationship(toFileId otherFileId: Int64, type: RelationshipType) async {
        guard let fileId = file.id else { return }
        do {
            try await environment.suggestionReview.createRelationship(fromFileId: fileId, toFileId: otherFileId, type: type)
            await loadRelationships()
        } catch { lastError = "\(error)" }
    }
}
