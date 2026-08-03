import Combine
import Foundation
import GRDB
import SpoolCore

/// Drives the menu bar's "N files pending" line off `ValueObservation`, same
/// live-update convention as `LibraryViewModel` — the count stays current whether or
/// not the dropdown is currently open, since the observation runs for as long as this
/// view model (owned by `MenuBarContentView`, which SwiftUI keeps resident for the
/// app's lifetime as part of the `MenuBarExtra` scene) is alive.
@MainActor
final class MenuBarStatusViewModel: ObservableObject {
    @Published private(set) var pendingJobCount: Int = 0

    private var observationTask: Task<Void, Never>?

    func start(writer: any DatabaseWriter) {
        guard observationTask == nil else { return }
        let observation = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM jobs WHERE status IN ('queued', 'running')
                """) ?? 0
        }
        observationTask = Task { [weak self] in
            do {
                for try await count in observation.values(in: writer) {
                    guard !Task.isCancelled else { return }
                    self?.pendingJobCount = count
                }
            } catch {
                // Observation ended/cancelled — nothing to recover here, mirrors
                // LibraryViewModel's own handling of this same error path.
            }
        }
    }
}
