import Combine
import Foundation
import GRDB
import SpoolCore

/// A file only ever gets one suggested-project membership from
/// `ProjectSuggestionService` today, but nothing in the schema enforces that — a
/// `ForEach` keyed on `fileId` alone would silently break (SwiftUI requires unique
/// ids) the day that stops being true, so this carries its own always-unique id.
struct SuggestedProjectMembershipEntry: Identifiable {
    let membership: ProjectFile
    let file: SpoolFile
    let project: Project
    var id: String { "\(membership.projectId)-\(membership.fileId)" }
}

@MainActor
final class AdminViewModel: ObservableObject {
    @Published private(set) var duplicateGroups: [DuplicateGroup] = []
    @Published private(set) var suggestedRelationships: [(relationship: Relationship, fromFile: SpoolFile, toFile: SpoolFile)] = []
    @Published private(set) var suggestedProjectMemberships: [SuggestedProjectMembershipEntry] = []
    @Published private(set) var pendingArchives: [ZipFile] = []
    @Published private(set) var rejectedArchives: [ZipFile] = []
    @Published private(set) var unsupportedArchives: [ZipFile] = []
    @Published var lastError: String?
    @Published private(set) var ingestionTotals: IngestionTotals?
    @Published private(set) var jobQueueCounts: [JobQueueCount] = []
    @Published private(set) var runningJobs: [RunningJobInfo] = []
    @Published private(set) var recentActivity: [RecentJobActivity] = []

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func load() async {
        do {
            duplicateGroups = try await environment.duplicates.listDuplicateGroups()
            try await loadSuggestedRelationships()
            try await loadSuggestedProjectMemberships()
            pendingArchives = try await environment.archiveReview.pendingArchives()
            rejectedArchives = try await environment.archiveReview.rejectedArchives()
            unsupportedArchives = try await environment.archiveReview.unsupportedArchives()
        } catch {
            lastError = "\(error)"
        }
    }

    func loadStatus() async {
        do {
            async let totals = environment.jobQueueStatus.ingestionTotals()
            async let queue = environment.jobQueueStatus.queueSummary()
            async let running = environment.jobQueueStatus.runningJobs()
            async let activity = environment.jobQueueStatus.recentActivity()
            ingestionTotals = try await totals
            jobQueueCounts = try await queue
            runningJobs = try await running
            recentActivity = try await activity
        } catch {
            lastError = "\(error)"
        }
    }

    func confirmArchive(_ zip: ZipFile) async {
        guard let id = zip.id else { return }
        do {
            try await environment.archiveReview.confirm(zipFileId: id)
            pendingArchives = try await environment.archiveReview.pendingArchives()
        } catch { lastError = "\(error)" }
    }

    func rejectArchive(_ zip: ZipFile) async {
        guard let id = zip.id else { return }
        do {
            try await environment.archiveReview.reject(zipFileId: id)
            pendingArchives = try await environment.archiveReview.pendingArchives()
            rejectedArchives = try await environment.archiveReview.rejectedArchives()
        } catch { lastError = "\(error)" }
    }

    func unrejectArchive(_ zip: ZipFile) async {
        guard let id = zip.id else { return }
        do {
            try await environment.archiveReview.unreject(zipFileId: id)
            pendingArchives = try await environment.archiveReview.pendingArchives()
            rejectedArchives = try await environment.archiveReview.rejectedArchives()
        } catch { lastError = "\(error)" }
    }

    /// An archive staged as unsupported before an external tool was configured stays
    /// that way forever otherwise — nothing re-inspects it on its own, since
    /// `ArchiveInspectionService.inspect`'s own (path, content_hash) uniqueness check
    /// treats an already-known row as, well, already known. Silently does nothing
    /// (besides refreshing the lists, which is a no-op if nothing changed) if a tool
    /// still isn't available or this one genuinely still isn't relevant.
    func recheckUnsupportedArchive(_ zip: ZipFile) async {
        guard let id = zip.id else { return }
        do {
            _ = try await environment.archiveReview.recheckUnsupported(zipFileId: id)
            pendingArchives = try await environment.archiveReview.pendingArchives()
            unsupportedArchives = try await environment.archiveReview.unsupportedArchives()
        } catch { lastError = "\(error)" }
    }

    func confirmSelectedArchives(ids: Set<Int64>) async {
        do {
            try await environment.archiveReview.confirm(zipFileIds: Array(ids))
            pendingArchives = try await environment.archiveReview.pendingArchives()
        } catch { lastError = "\(error)" }
    }

    func confirmAllArchives() async {
        do {
            _ = try await environment.archiveReview.confirmAll()
            pendingArchives = try await environment.archiveReview.pendingArchives()
        } catch { lastError = "\(error)" }
    }

    private func loadSuggestedRelationships() async throws {
        let rels = try await environment.suggestionReview.suggestedRelationships()
        suggestedRelationships = try await environment.database.writer.read { conn in
            try rels.compactMap { rel -> (Relationship, SpoolFile, SpoolFile)? in
                guard let from = try SpoolFile.fetchOne(conn, id: rel.fromFileId),
                      let to = try SpoolFile.fetchOne(conn, id: rel.toFileId) else { return nil }
                return (rel, from, to)
            }
        }
    }

    private func loadSuggestedProjectMemberships() async throws {
        let memberships = try await environment.suggestionReview.suggestedProjectMemberships()
        suggestedProjectMemberships = try await environment.database.writer.read { conn in
            try memberships.compactMap { membership -> SuggestedProjectMembershipEntry? in
                guard let file = try SpoolFile.fetchOne(conn, id: membership.fileId),
                      let project = try Project.fetchOne(conn, id: membership.projectId) else { return nil }
                return SuggestedProjectMembershipEntry(membership: membership, file: file, project: project)
            }
        }
    }

    func deleteDuplicate(_ file: SpoolFile) async {
        guard let fileId = file.id else { return }
        do {
            try await environment.duplicates.deleteDuplicate(fileId: fileId)
            duplicateGroups = try await environment.duplicates.listDuplicateGroups()
        } catch DuplicateService.DeletionError.cannotDeleteFromLibraryRoot {
            lastError = "\(file.filename) lives in your read-only Library folder and can't be deleted from Spool — remove it in Finder instead."
        } catch {
            lastError = "\(error)"
        }
    }

    /// Deletes every "extra" copy across every duplicate group in one action — keeps
    /// one true copy per group (the oldest, or the Library copy if one exists) and
    /// trashes the rest.
    func deleteAllDuplicates() async {
        do {
            _ = try await environment.duplicates.deleteAllDuplicates()
            duplicateGroups = try await environment.duplicates.listDuplicateGroups()
        } catch {
            lastError = "\(error)"
        }
    }

    func confirmRelationship(_ relationship: Relationship) async {
        guard let id = relationship.id else { return }
        do {
            try await environment.suggestionReview.confirmRelationship(id: id)
            try await loadSuggestedRelationships()
        } catch { lastError = "\(error)" }
    }

    func rejectRelationship(_ relationship: Relationship) async {
        guard let id = relationship.id else { return }
        do {
            try await environment.suggestionReview.rejectRelationship(id: id)
            try await loadSuggestedRelationships()
        } catch { lastError = "\(error)" }
    }

    func confirmSelectedRelationships(ids: Set<Int64>) async {
        do {
            try await environment.suggestionReview.confirmRelationships(ids: Array(ids))
            try await loadSuggestedRelationships()
        } catch { lastError = "\(error)" }
    }

    func confirmAllRelationships() async {
        do {
            _ = try await environment.suggestionReview.confirmAllSuggestedRelationships()
            try await loadSuggestedRelationships()
        } catch { lastError = "\(error)" }
    }

    func confirmProjectMembership(_ membership: ProjectFile) async {
        do {
            try await environment.suggestionReview.confirmProjectMembership(projectId: membership.projectId, fileId: membership.fileId)
            try await loadSuggestedProjectMemberships()
        } catch { lastError = "\(error)" }
    }

    func rejectProjectMembership(_ membership: ProjectFile) async {
        do {
            try await environment.suggestionReview.rejectProjectMembership(projectId: membership.projectId, fileId: membership.fileId)
            try await loadSuggestedProjectMemberships()
        } catch { lastError = "\(error)" }
    }

    func confirmSelectedProjectMemberships(_ pairs: [(projectId: Int64, fileId: Int64)]) async {
        do {
            try await environment.suggestionReview.confirmProjectMemberships(pairs)
            try await loadSuggestedProjectMemberships()
        } catch { lastError = "\(error)" }
    }

    func confirmAllProjectMemberships() async {
        do {
            _ = try await environment.suggestionReview.confirmAllSuggestedProjectMemberships()
            try await loadSuggestedProjectMemberships()
        } catch { lastError = "\(error)" }
    }

}
