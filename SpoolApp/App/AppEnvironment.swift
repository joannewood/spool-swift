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
    // Holds the security scope open for the app's lifetime, same convention as
    // `RootAccessManager` — see `resolveArchiveToolAccess`.
    private var archiveToolAccess: SecurityScopedAccess?

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
        self.printMetadata = PrintMetadataService(writer: database.writer)
        self.printLog = PrintLogService(writer: database.writer)
        self.projects = ProjectService(writer: database.writer)
        self.duplicates = DuplicateService(writer: database.writer)
        self.suggestionReview = SuggestionReviewService(writer: database.writer)
        self.appSettings = AppSettingsService(writer: database.writer)
        self.detectedApps = InstalledAppDetector.detectAll()

        // Resolved synchronously, once, here — everything below that needs it
        // (BackfillService/RescanService/ExtractZipJobHandler) is constructed
        // synchronously in this same init, before `start()`'s async work even begins.
        // A settings change made later in Settings takes effect on next launch, not
        // live — see the picker's UI copy.
        let archiveToolAccess = Self.resolveArchiveToolAccess(writer: database.writer)
        self.archiveToolAccess = archiveToolAccess
        let externalArchiveToolURL = archiveToolAccess?.url

        // IngestJobHandler (and ArchiveReviewService.confirm, below) need a JobEnqueuer
        // to dispatch a follow-up job — but that enqueuer *is* the JobQueue being
        // constructed right here, which itself needs the handlers up front.
        // DeferredJobEnqueuer breaks the cycle: build handlers/services against it,
        // construct the queue, then attach.
        let deferredEnqueuer = DeferredJobEnqueuer()
        self.archiveReview = ArchiveReviewService(writer: database.writer, enqueuer: deferredEnqueuer)

        let handlers = JobHandlers(
            ingest: IngestJobHandler(writer: database.writer, enqueuer: deferredEnqueuer),
            render: RenderJobHandler(writer: database.writer, thumbnailsDirectory: thumbnailsDirectory),
            renderStep: StepTessellationJobHandler(writer: database.writer, thumbnailsDirectory: thumbnailsDirectory),
            rescan: NoOpJobHandler(),
            extractZip: ExtractZipJobHandler(writer: database.writer, externalToolURL: externalArchiveToolURL)
        )
        let jobQueue = JobQueue(writer: database.writer, handlers: handlers)
        self.jobQueue = jobQueue
        self.deferredEnqueuer = deferredEnqueuer
        let backfill = BackfillService(
            writer: database.writer, enqueuer: jobQueue, thumbnailsDirectory: thumbnailsDirectory,
            externalArchiveToolURL: externalArchiveToolURL
        )
        self.backfill = backfill
        self.rescan = RescanService(
            writer: database.writer, enqueuer: jobQueue, backfill: backfill, thumbnailsDirectory: thumbnailsDirectory,
            externalArchiveToolURL: externalArchiveToolURL
        )
        self.liveWatch = LiveWatchCoordinator(backfill: backfill)
    }

    func start() async {
        // Must complete before the queue starts claiming jobs — an ingest job that
        // runs before this attaches would fail to dispatch its follow-up render job.
        await deferredEnqueuer.attach(jobQueue)
        try? await rootAccess.resolveAll()
        await jobQueue.start()
        await backfillAllActiveRoots()
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

    /// Re-walks every active root's tree, staging anything not yet known. Safe to call
    /// repeatedly — cheap when there's nothing new (`files.path` is `UNIQUE`).
    func backfillAllActiveRoots() async {
        let rootsWithURLs = await activeRootsWithResolvedURLs()
        let dropFolderRoot = rootsWithURLs.first { $0.0.kind == .dropFolder }
        for (root, url) in rootsWithURLs {
            _ = try? await backfill.run(root: root, rootURL: url, dropFolderRoot: dropFolderRoot)
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

    /// A missing/unresolvable bookmark is not an error — "no external archive tool
    /// configured" is a fully supported state (.7z/.rar archives just show as
    /// unsupported), so every failure path here silently returns `nil` rather than
    /// throwing and blocking app launch over an optional feature.
    private static func resolveArchiveToolAccess(writer: any DatabaseWriter) -> SecurityScopedAccess? {
        guard let data = try? writer.read({ conn in
            try AppSettings.fetchOne(conn, key: AppSettings.singletonId)
        })?.archiveToolBookmarkData else { return nil }
        return try? SecurityScopedAccess.resolve(bookmarkData: data)
    }

    private static func makeThumbnailsDirectory() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("Thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
