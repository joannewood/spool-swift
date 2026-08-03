import Combine
import Foundation
import SpoolCore

/// Loads every project once and builds the parent/child tree client-side — personal
/// library scale (tens, not thousands, of projects) makes this simpler and cheap
/// enough that a lazy per-node fetch would just be extra roundtrips for no benefit.
@MainActor
final class ProjectsViewModel: ObservableObject {
    @Published private(set) var allProjects: [Project] = []
    @Published var lastError: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func load() async {
        do {
            allProjects = try await environment.projects.allProjects()
        } catch {
            lastError = "\(error)"
        }
    }

    func children(ofParentId parentId: Int64?) -> [Project] {
        allProjects.filter { $0.parentProjectId == parentId }
    }

    func hasChildren(_ project: Project) -> Bool {
        guard let id = project.id else { return false }
        return allProjects.contains { $0.parentProjectId == id }
    }

    /// Every descendant at any depth — used to exclude a project (and anything nested
    /// under it) from "Merge Into…"/"Move to…" pickers, since merging or reparenting a
    /// project into its own descendant would create a cycle or a meaningless no-op.
    func descendantIds(of projectId: Int64) -> Set<Int64> {
        var result: Set<Int64> = []
        var queue = children(ofParentId: projectId).compactMap(\.id)
        while let id = queue.popLast() {
            result.insert(id)
            queue.append(contentsOf: children(ofParentId: id).compactMap(\.id))
        }
        return result
    }

    @discardableResult
    func createProject(name: String, parentProjectId: Int64? = nil) async -> Project? {
        do {
            let project = try await environment.projects.createProject(name: name, parentProjectId: parentProjectId)
            await load()
            return project
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    func rename(_ project: Project, to newName: String) async {
        guard let id = project.id else { return }
        do {
            try await environment.projects.rename(projectId: id, to: newName)
            await load()
        } catch { lastError = "\(error)" }
    }

    /// `newParentId == nil` moves the project back to the top level.
    func reparent(_ project: Project, toParentId newParentId: Int64?) async {
        guard let id = project.id else { return }
        do {
            try await environment.projects.reparent(projectId: id, toParentId: newParentId)
            await load()
        } catch { lastError = "\(error)" }
    }

    func setColor(_ project: Project, to color: ProjectColor) async {
        guard let id = project.id else { return }
        do {
            try await environment.projects.setColor(projectId: id, to: color)
            await load()
        } catch { lastError = "\(error)" }
    }
}
