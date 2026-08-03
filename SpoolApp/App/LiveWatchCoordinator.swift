import Foundation
import SpoolCore
import SpoolFS

/// Owns one `FSEventsWatcher` + `SettlementTracker` pair per actively-watched root,
/// routing settled paths into `BackfillService.stageIfNew` — the live-ingestion
/// counterpart to the startup/on-grant backfill walk. This, plus that walk, is the
/// full native replacement for the source app's watchdog-based watcher + 10s
/// `watched_roots` poll: as long as the app is running, every active root is both
/// walked once and watched continuously.
@MainActor
final class LiveWatchCoordinator {
    private let backfill: BackfillService
    private var watchers: [Int64: FSEventsWatcher] = [:]
    private var drainTasks: [Int64: Task<Void, Never>] = [:]

    init(backfill: BackfillService) {
        self.backfill = backfill
    }

    func startWatching(root: WatchedRoot, rootURL: URL, dropFolderRoot: (root: WatchedRoot, url: URL)? = nil) {
        guard let rootId = root.id, watchers[rootId] == nil else { return }

        let backfillRef = backfill
        let tracker = SettlementTracker { path in
            Task {
                _ = try? await backfillRef.stageIfNew(
                    path: path, root: root, rootURL: rootURL, dropFolderRoot: dropFolderRoot
                )
            }
        }

        let watcher = FSEventsWatcher(paths: [rootURL.path])
        watchers[rootId] = watcher
        drainTasks[rootId] = Task {
            for await event in watcher.events {
                guard !event.isDirectory, !event.isRemoved else { continue }
                await tracker.markDirty(event.path)
            }
        }
        watcher.start()
    }

    func stopWatching(rootId: Int64) {
        watchers[rootId]?.stop()
        watchers[rootId] = nil
        drainTasks[rootId]?.cancel()
        drainTasks[rootId] = nil
    }

    func stopAll() {
        for id in Array(watchers.keys) {
            stopWatching(rootId: id)
        }
    }
}
