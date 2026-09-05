import Combine
import Foundation
import GRDB
import SpoolCore
import SpoolFS

/// Wires together the app's long-lived singletons: the on-disk database, the watched-
/// root repository, the job queue (with real ingest/render handlers as of M1 — extract-
/// zip stays `NoOpJobHandler` until M4/later), the backfill service used both at launch
/// and whenever a new root is granted, and the periodic rescan loop (native equivalent
/// of the source app's timer-driven `run_rescan` — not a queued job type, matching that
/// same architecture). One instance, created once at launch and handed down via the
/// SwiftUI environment.
@MainActor
final class AppEnvironment: ObservableObject {
    let database: SQLiteSpoolDatabase
    let watchedRoots: WatchedRootRepository
    let rootAccess: RootAccessManager
    let jobQueue: JobQueue
    let backfill: BackfillService
    let rescan: RescanService
    let liveWatch: LiveWatchCoordinator
    let thumbnailsDirectory: URL
    let tags: TagService
    let files: FileService
    let search: SearchService
    let jobQueueStatus: JobQueueStatusService
    let sidecars: SidecarService
    let gallery: FileGalleryService
    let printMetadata: PrintMetadataService
    let printLog: PrintLogService
    let projects: ProjectService
    let duplicates: DuplicateService
    let suggestionReview: SuggestionReviewService
    let appSettings: AppSettingsService
    let archiveReview: ArchiveReviewService
    let detectedApps: [DetectedApp]
    private let deferredEnqueuer: DeferredJobEnqueuer
    private var rescanTask: Task<Void, Never>?

    init() throws {
        let database = try SQLiteSpoolDatabase(path: try SQLiteSpoolDatabase.defaultPath())
        self.database = database
        self.watchedRoots = WatchedRootRepository(writer: database.writer)
        self.rootAccess = RootAccessManager(repository: watchedRoots)
        self.thumbnailsDirectory = try Self.makeThumbnailsDirectory()
        self.tags = TagService(writer: database.writer)
        self.files = FileService(writer: database.writer)
        self.search = SearchService(writer: database.writer)
        self.jobQueueStatus = JobQueueStatusService(writer: database.writer)
        self.sidecars = SidecarService(writer: database.writer, thumbnailsDirectory: thumbnailsDirectory)
        self.gallery = FileGalleryService(writer: database.writer, thumbnailsDirectory: thumbnailsDirectory)
        self.printMetadata = PrintMetadataService(writer: database.writer)
        self.printLog = PrintLogService(writer: database.writer)
        self.projects = ProjectService(writer: database.writer)
        self.duplicates = DuplicateService(writer: database.writer)
        self.suggestionReview = SuggestionReviewService(writer: database.writer)
        self.appSettings = AppSettingsService(writer: database.writer)
        self.detectedApps = InstalledAppDetector.detectAll()

        // IngestJobHandler (and ArchiveReviewService.confirm, below) need a JobEnqueuer
        // to dispatch a follow-up job — but that enqueuer *is* the JobQueue being
        // constructed right here, which itself needs the handlers up front.
        // DeferredJobEnqueuer breaks the cycle: build handlers/services against it,
        // construct the queue, then attach.
        let deferredEnqueuer = DeferredJobEnqueuer()
        self.archiveReview = ArchiveReviewService(writer: database.writer, enqueuer: deferredEnqueuer)

        let handlers = JobHandlers(
            ingest: IngestJobHandler(writer: database.writer, enqueuer: deferredEnqueuer, thumbnailsDirectory: thumbnailsDirectory),
            render: RenderJobHandler(writer: database.writer, thumbnailsDirectory: thumbnailsDirectory),
            renderStep: StepTessellationJobHandler(writer: database.writer, thumbnailsDirectory: thumbnailsDirectory),
            rescan: NoOpJobHandler(),
            extractZip: ExtractZipJobHandler(writer: database.writer)
        )
        let jobQueue = JobQueue(writer: database.writer, handlers: handlers)
        self.jobQueue = jobQueue
        self.deferredEnqueuer = deferredEnqueuer
        let backfill = BackfillService(writer: database.writer, enqueuer: jobQueue, thumbnailsDirectory: thumbnailsDirectory)
        self.backfill = backfill
        self.rescan = RescanService(
            writer: database.writer, enqueuer: jobQueue, backfill: backfill, thumbnailsDirectory: thumbnailsDirectory
        )
        self.liveWatch = LiveWatchCoordinator(backfill: backfill)
    }

    func start() async {
        // Must complete before the queue starts claiming jobs — an ingest job that
        // runs before this attaches would fail to dispatch its follow-up render job.
        await deferredEnqueuer.attach(jobQueue)
        try? await rootAccess.resolveAll()
        await jobQueue.start()
        // Deliberately NOT `backfillAllActiveRoots()` here — confirmed live as a real
        // bug: `RescanService.run` is already a strict superset of `BackfillService.run`
        // (its own "genuinely new path" branch falls through to `backfill.stageIfNew`),
        // but backfill's blind "not in knownPaths → stage as new" check has no idea a
        // path might be a *move* of a file that's still in the DB at its old, now-gone
        // location. Running backfill first at every launch meant any file moved/renamed
        // on disk while the app was closed (a real production scenario: an external tool
        // reorganizing the watched folders overnight) got a brand-new file/project row
        // instead of being reunified by content hash — permanently losing its tags/
        // relationships/print history, and leaving the old row stuck `missing` forever
        // with an orphaned auto-created project shell (`ProjectCleanup` only sweeps a
        // project whose *file rows* are gone outright, not merely `missing`). Starting
        // straight from the first (immediate, no-initial-sleep) periodic rescan pass
        // gives every launch — not just the steady-state 300s cycle — the hash-based
        // move check before anything can claim a path as new.
        startWatchingAllActiveRoots()
        startPeriodicRescan()
    }

    /// Native equivalent of the source app's timer-driven worker loop: sleeps for
    /// `app_settings.rescan_interval_seconds` (re-read every cycle, so a settings change
    /// takes effect on the next tick without a restart), skipping the walk entirely
    /// while `rescan_enabled` is off — matching that same pause/resume behavior.
    private func startPeriodicRescan() {
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let settings = (try? await self.appSettings.get()) ?? AppSettings()
                if settings.rescanEnabled {
                    await self.rescanAllActiveRoots()
                }
                let interval = max(settings.rescanIntervalSeconds, AppSettings.minRescanIntervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    /// Re-walks every active root's tree, reconciling drift/moves/missing files against
    /// what's actually on disk. Safe to call repeatedly — a no-op cost-wise when nothing
    /// has changed since the last pass.
    func rescanAllActiveRoots() async {
        let rootsWithURLs = await activeRootsWithResolvedURLs()
        let dropFolderRoot = rootsWithURLs.first { $0.0.kind == .dropFolder }
        for (root, url) in rootsWithURLs {
            _ = try? await rescan.run(root: root, rootURL: url, dropFolderRoot: dropFolderRoot)
        }
    }

    func startWatchingAllActiveRoots() {
        Task {
            let rootsWithURLs = await activeRootsWithResolvedURLs()
            let dropFolderRoot = rootsWithURLs.first { $0.0.kind == .dropFolder }
            for (root, url) in rootsWithURLs {
                liveWatch.startWatching(root: root, rootURL: url, dropFolderRoot: dropFolderRoot)
            }
        }
    }

    private func activeRootsWithResolvedURLs() async -> [(WatchedRoot, URL)] {
        guard let roots = try? await watchedRoots.fetchActive() else { return [] }
        return roots.compactMap { root in
            guard let rootId = root.id, let url = rootAccess.url(forRootId: rootId) else { return nil }
            return (root, url)
        }
    }

    private static func makeThumbnailsDirectory() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
