import Foundation
import SpoolCore

enum LibrarySelection: Hashable {
    case allFiles
    case project(Int64)
}

/// Reads whatever the Mac most recently exported — no live connection, just "fetch on
/// appear" (and on pull-to-refresh), matching the accepted sync lag. Kept deliberately
/// simple compared to the Mac app's `LibraryViewModel`: no live `ValueObservation` (the
/// underlying file barely changes within a session), no filters/sort UI yet — just
/// search, matching this app's much smaller "browse and pick something to print" scope.
@MainActor
final class LibraryBrowseViewModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var files: [SpoolFile] = []
    @Published var selection: LibrarySelection = .allFiles
    @Published var searchQuery: String = ""
    @Published var lastError: String?

    private var database: SQLiteSpoolDatabase?

    func refresh(database: SQLiteSpoolDatabase?) async {
        self.database = database
        guard let database else {
            projects = []
            files = []
            return
        }
        do {
            projects = try await ProjectService(writer: database.writer).allProjects()
        } catch {
            lastError = "\(error)"
        }
        await reloadFiles()
    }

    func reloadFiles() async {
        guard let database else { return }
        do {
            if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                files = try await SearchService(writer: database.writer).search(query: searchQuery)
            } else if case .project(let projectId) = selection {
                files = try await ProjectService(writer: database.writer).confirmedFiles(inProjectId: projectId)
            } else {
                files = try await SearchService(writer: database.writer).search()
            }
        } catch {
            lastError = "\(error)"
        }
    }
}
