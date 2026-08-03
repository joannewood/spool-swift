import Combine
import Foundation
import SpoolCore
import SpoolFS

@MainActor
final class RootsViewModel: ObservableObject {
    @Published private(set) var roots: [WatchedRoot] = []
    @Published var lastError: String?

    private let repository: WatchedRootRepository
    private let rootAccess: RootAccessManager
    private let backfill: BackfillService
    private let liveWatch: LiveWatchCoordinator

    init(
        repository: WatchedRootRepository,
        rootAccess: RootAccessManager,
        backfill: BackfillService,
        liveWatch: LiveWatchCoordinator
    ) {
        self.repository = repository
        self.rootAccess = rootAccess
        self.backfill = backfill
        self.liveWatch = liveWatch
    }

    func refresh() async {
        do {
            roots = try await repository.fetchAll()
        } catch {
            lastError = "Couldn't load watched roots: \(error)"
        }
    }

    /// Onboarding flow for one root: pick a folder, capture a security-scoped
    /// bookmark, persist it, then resolve access immediately so it's usable without
    /// relaunching. `kind`/`label` decide which of the three roots this is (drop
    /// folder / library / downloads) — see the source app's "Setting up on your own
    /// machine" README section for what each means.
    func addRoot(kind: RootKind, label: String) async {
        guard let url = FolderPickerService.pickFolder(prompt: "Grant Access") else { return }
        do {
            let bookmarkData = try SecurityScopedBookmark.create(for: url)
            let root = WatchedRoot(
                hostPath: url.path,
                label: label,
                kind: kind,
                ingestMode: kind == .downloads ? .relocateToDropfolder : .indexInPlace,
                bookmarkData: bookmarkData
            )
            let inserted = try await repository.add(root)
            let resolvedURL = try rootAccess.resolve(inserted)
            await refresh()
            // Don't make the user wait for the next launch to see anything — walk the
            // newly-granted folder now, then keep watching it live from here on.
            let dropFolderRoot = currentDropFolderRoot()
            _ = try? await backfill.run(root: inserted, rootURL: resolvedURL, dropFolderRoot: dropFolderRoot)
            liveWatch.startWatching(root: inserted, rootURL: resolvedURL, dropFolderRoot: dropFolderRoot)
        } catch {
            lastError = "Couldn't add \(label): \(error)"
        }
    }

    /// The active drop-folder root + its resolved URL, needed whenever a
    /// `.relocateToDropfolder` root (a `downloads`-kind root) is walked or watched — nil
    /// if the drop folder hasn't been granted yet, in which case that root is indexed in
    /// place rather than relocated (a deliberate GUI-app-friendly fallback: unlike the
    /// source app's background worker, there's no "crash the whole process" equivalent
    /// here worth reproducing for a one-time onboarding-order edge case).
    private func currentDropFolderRoot() -> (root: WatchedRoot, url: URL)? {
        guard let dropRoot = roots.first(where: { $0.kind == .dropFolder }),
              let id = dropRoot.id,
              let url = rootAccess.url(forRootId: id) else { return nil }
        return (dropRoot, url)
    }

    /// Edits an existing root: label and active are always applied; `ingestMode` is
    /// only actually applied for `.library` roots (see `WatchedRootRepository.update`) —
    /// a drop folder / downloads root each have exactly one sane ingest mode implied by
    /// their role, fixed at grant time. Pausing (`active: false`) stops live-watching
    /// immediately; resuming re-resolves access and restarts watching right away rather
    /// than waiting for the next launch.
    func update(_ root: WatchedRoot, label: String, ingestMode: RootIngestMode, active: Bool) async {
        guard let id = root.id else { return }
        do {
            try await repository.update(id: id, label: label, ingestMode: ingestMode, active: active)
            await refresh()
            if !active {
                liveWatch.stopWatching(rootId: id)
            } else if let updated = roots.first(where: { $0.id == id }), let url = try? rootAccess.resolve(updated) {
                let dropFolderRoot = currentDropFolderRoot()
                liveWatch.startWatching(root: updated, rootURL: url, dropFolderRoot: dropFolderRoot)
            }
        } catch {
            lastError = "Couldn't update \(root.label): \(error)"
        }
    }

    func remove(_ root: WatchedRoot) async {
        guard let id = root.id else { return }
        do {
            try await repository.remove(id: id)
            await refresh()
        } catch {
            lastError = "Couldn't remove \(root.label): \(error)"
        }
    }
}
