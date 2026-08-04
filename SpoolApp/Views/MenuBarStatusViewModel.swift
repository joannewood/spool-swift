import Combine
import Foundation
import GRDB
import SpoolCore

/// Drives the menu bar dropdown's status lines off `ValueObservation`, same live-update
/// convention as `LibraryViewModel` — stays current whether or not the dropdown is
/// currently open, since the observation runs for as long as this view model (owned by
/// `MenuBarContentView`, which SwiftUI keeps resident for the app's lifetime as part of
/// the `MenuBarExtra` scene) is alive.
///
/// Deliberately *one* `ValueObservation`/one `@Published` struct, not two independent
/// ones (job count, rescan schedule) each publishing on their own — confirmed live as a
/// real crash: two separate observations on the same view model occasionally emitted
/// close together right as the dropdown opened, and `MenuBarExtra`'s AppKit-menu
/// bridging responded to that with unbounded recursion (`MenuBehavior
/// .menuHostDidChangeMenuItems` calling back into the render pass that triggered it,
/// forever) — `EXC_BAD_ACCESS`, "Thread stack size exceeded due to excessive
/// recursion". One observation means at most one `@Published` mutation per underlying
/// DB change, never two back-to-back.
@MainActor
final class MenuBarStatusViewModel: ObservableObject {
    struct Status: Equatable {
        var pendingJobCount = 0
        var rescanEnabled = true
        /// `nil` when no root has ever been scanned yet (still mid-backfill) — the
        /// dropdown just omits the line in that case rather than showing a nonsense date.
        var nextScanAt: Date?
    }

    @Published private(set) var status = Status()

    private var observationTask: Task<Void, Never>?

    func start(writer: any DatabaseWriter) {
        guard observationTask == nil else { return }
        let observation = ValueObservation.tracking { db -> Status in
            let pendingJobCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM jobs WHERE status IN ('queued', 'running')
                """) ?? 0
            let settings = try AppSettings.fetchOne(db, key: AppSettings.singletonId) ?? AppSettings()
            let lastScannedAt = try Date.fetchOne(db, sql: "SELECT MAX(last_scanned_at) FROM watched_roots WHERE active = 1")
            let nextScanAt = lastScannedAt.map { $0.addingTimeInterval(TimeInterval(settings.rescanIntervalSeconds)) }
            return Status(pendingJobCount: pendingJobCount, rescanEnabled: settings.rescanEnabled, nextScanAt: nextScanAt)
        }
        observationTask = Task { [weak self] in
            do {
                for try await status in observation.values(in: writer) {
                    guard !Task.isCancelled else { return }
                    self?.status = status
                }
            } catch {
                // Observation ended/cancelled — nothing to recover here, mirrors
                // LibraryViewModel's own handling of this same error path.
            }
        }
    }
}
