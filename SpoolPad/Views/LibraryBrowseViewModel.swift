import Foundation
import GRDB
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

    /// Set once by the view (to `{ libraryAccess.reload(); return libraryAccess.database }`)
    /// so a stale connection can reopen itself — see `retryingOnStaleConnection`.
    var reopenDatabase: (() -> SQLiteSpoolDatabase?)?

    func refresh(database: SQLiteSpoolDatabase?) async {
        self.database = database
        guard database != nil else {
            projects = []
            files = []
            return
        }
        // Reads `self.database` fresh on each attempt, not a captured local constant —
        // a retry reassigns `self.database` first (see `retryingOnStaleConnection`), so
        // the closure must look it up again rather than keep using the stale one.
        await retryingOnStaleConnection {
            guard let database = self.database else { return }
            self.projects = try await ProjectService(writer: database.writer).allProjects()
        }
        await reloadFiles()
    }

    func reloadFiles() async {
        guard database != nil else { return }
        await retryingOnStaleConnection {
            guard let database = self.database else { return }
            if !self.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                self.files = try await SearchService(writer: database.writer).search(query: self.searchQuery)
            } else if case .project(let projectId) = self.selection {
                self.files = try await ProjectService(writer: database.writer).confirmedFiles(inProjectId: projectId)
            } else {
                self.files = try await SearchService(writer: database.writer).search()
            }
        }
    }

    /// The Mac's periodic re-export swaps `library.sqlite` into place with an atomic
    /// rename (see `IPadExportService`), but a connection already open from *before*
    /// that swap can still have its next query throw `SQLITE_IOERR` — confirmed live on
    /// a real iPad, and reproduced deliberately in a standalone GRDB test
    /// (`IPadExportServiceTests.freshOpensDuringConcurrentReExportAlwaysSeeACompleteDatabase`'s
    /// doc comment has the full explanation). That's real SQLite/VFS behavior, not
    /// something a write-side fix alone can close — the correct response here is to
    /// reopen a fresh connection and retry once, not surface a hard, unrecoverable
    /// error to someone who did nothing wrong.
    private func retryingOnStaleConnection(_ operation: () async throws -> Void) async {
        do {
            try await operation()
        } catch {
            guard let dbError = error as? DatabaseError, dbError.resultCode == .SQLITE_IOERR,
                  let fresh = reopenDatabase?() else {
                lastError = "\(error)"
                return
            }
            database = fresh
            do {
                try await operation()
            } catch {
                lastError = "\(error)"
            }
        }
    }
}
