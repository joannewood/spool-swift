import Foundation
import GRDB

/// Re-walks a watched root's tree, reconciling every already-known file against what's
/// actually on disk — the native equivalent of the source app's periodic `run_rescan`.
/// Unlike `BackfillService.run` (which only cares about brand-new files), this also:
/// detects drift on a known file (cheap size/mtime stat gates an expensive re-hash),
/// detects a move/rename by content-hash match against a not-yet-seen active row from
/// the same root (preserving tags/relationships/project membership, since the same DB
/// row is repointed rather than replaced), and marks a vanished file/sidecar `missing`
/// rather than deleting its row outright.
public actor RescanService {
    private static let archiveExtensions: Set<String> = ["zip", "7z", "rar"]

    public struct Summary: Equatable, Sendable {
        public var newCount = 0
        public var rehashedCount = 0
        public var revivedCount = 0
        public var movedCount = 0
        public var missingCount = 0
        public var sidecarMissingCount = 0
    }

    private enum ReconcileOutcome {
        case unchanged, touched, revived, rehashed
    }

    private let writer: any DatabaseWriter
    private let enqueuer: any JobEnqueuer
    private let archiveInspection: ArchiveInspectionService
    private let sidecars: SidecarService
    private let backfill: BackfillService
    private let fileManager = FileManager.default

    /// `backfill` is reused for the "genuinely new file" branch — staging a not-yet-known
    /// model file (including relocating it for a `.relocateToDropfolder` root) is exactly
    /// `BackfillService.stageIfNew`'s job, and the source app shares this same step
    /// between `backfill.py` and `rescan.py` (`_ingest_new_path`) rather than duplicating it.
    public init(
        writer: any DatabaseWriter,
        enqueuer: any JobEnqueuer,
        backfill: BackfillService,
        thumbnailsDirectory: URL? = nil,
        externalArchiveToolURL: URL? = nil
    ) {
        self.writer = writer
        self.enqueuer = enqueuer
        self.archiveInspection = ArchiveInspectionService(writer: writer, enqueuer: enqueuer, externalToolURL: externalArchiveToolURL)
        self.sidecars = SidecarService(writer: writer, thumbnailsDirectory: thumbnailsDirectory)
        self.backfill = backfill
    }

    @discardableResult
    public func run(
        root: WatchedRoot,
        rootURL: URL,
        dropFolderRoot: (root: WatchedRoot, url: URL)? = nil
    ) async throws -> Summary {
        guard let rootId = root.id else { return Summary() }

        let knownFiles = try await writer.read { conn in
            try SpoolFile.filter(Column("watched_root_id") == rootId).fetchAll(conn)
        }
        var knownByPath: [String: SpoolFile] = [:]
        for file in knownFiles { knownByPath[file.path] = file }

        let knownSidecars = try await writer.read { conn in
            try SidecarFile.filter(Column("watched_root_id") == rootId).fetchAll(conn)
        }
        var knownSidecarsByPath: [String: SidecarFile] = [:]
        for sidecar in knownSidecars { knownSidecarsByPath[sidecar.path] = sidecar }

        // Only 'active' rows are move candidates — a row already 'missing' from a
        // *prior* rescan is presumed gone for real, not silently still-there-somewhere,
        // so a coincidental hash match doesn't resurrect an arbitrarily old missing row.
        var activeByHash: [String: [SpoolFile]] = [:]
        for file in knownFiles where file.status == .active {
            guard let hash = file.contentHash else { continue }
            activeByHash[hash, default: []].append(file)
        }

        var seenPaths: Set<String> = []
        var seenSidecarPaths: Set<String> = []
        var summary = Summary()

        let enumerator = fileManager.enumerator(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        // Materialized before any relocation happens — same reason as backfill: moving a
        // whole leaf folder mid-walk could otherwise disrupt the enumerator's
        // still-in-progress traversal of that same tree.
        var discovered: [URL] = []
        while let url = enumerator?.nextObject() as? URL { discovered.append(url) }

        for url in discovered {
            guard !JunkFilter.isIgnorable(url.lastPathComponent) else { continue }
            // A single unreadable/racy file must never abort the rest of this pass —
            // matching a real production incident in the source app where one bad file
            // silently blocked every other file's drift-check/rehash for that entire
            // cycle, every cycle (run_rescan had no per-file recovery of its own).
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true { continue }
                let ext = url.pathExtension.lowercased()

                if Self.archiveExtensions.contains(ext) {
                    try? await archiveInspection.inspect(path: url.path, watchedRootId: rootId)
                    continue
                }

                guard ModelExtension.all.contains(ext) else {
                    // See BackfillService.run for why relocate-mode roots skip sidecar
                    // reconciliation here — their sidecars either already moved with
                    // their folder or will be caught once that folder shows up in the
                    // drop folder's own walk.
                    if root.ingestMode != .relocateToDropfolder {
                        seenSidecarPaths.insert(url.path)
                        if try await reconcileSidecar(atPath: url.path, rootId: rootId, known: knownSidecarsByPath[url.path]) {
                            // no separate counter needed — matches the source app,
                            // which doesn't track sidecar revivals distinctly either.
                        }
                    }
                    continue
                }

                seenPaths.insert(url.path)

                if let existing = knownByPath[url.path] {
                    switch try await reconcileKnownFile(existing, atURL: url) {
                    case .rehashed: summary.rehashedCount += 1
                    case .revived: summary.revivedCount += 1
                    case .unchanged, .touched: break
                    }
                    continue
                }

                if let movedFrom = try findMoveSource(sourceURL: url, activeByHash: activeByHash, seenPaths: seenPaths),
                   let movedFromId = movedFrom.id {
                    try await repoint(fileId: movedFromId, newRootId: rootId, newContainerURL: url)
                    seenPaths.insert(movedFrom.path)
                    summary.movedCount += 1
                    continue
                }

                let stagedNew = try await backfill.stageIfNew(
                    path: url.path, root: root, rootURL: rootURL, dropFolderRoot: dropFolderRoot
                )
                if stagedNew { summary.newCount += 1 }
            } catch {
                continue
            }
        }

        let missingFileIds = knownByPath.values
            .filter { $0.status == .active && !seenPaths.contains($0.path) }
            .compactMap(\.id)
        let missingSidecarIds = knownSidecarsByPath.values
            .filter { $0.status == .active && !seenSidecarPaths.contains($0.path) }
            .compactMap(\.id)

        try await writer.write { conn in
            for id in missingFileIds {
                try conn.execute(sql: "UPDATE files SET status = 'missing' WHERE id = ?", arguments: [id])
            }
            for id in missingSidecarIds {
                try conn.execute(sql: "UPDATE sidecar_files SET status = 'missing' WHERE id = ?", arguments: [id])
            }
            try conn.execute(sql: "UPDATE watched_roots SET last_scanned_at = ? WHERE id = ?", arguments: [Date(), rootId])
        }
        summary.missingCount = missingFileIds.count
        summary.sidecarMissingCount = missingSidecarIds.count
        return summary
    }

    /// A cheap stat (size + mtime) gates the expensive re-hash. Deliberately does not
    /// re-run the relationship/folder-grouping suggestion heuristics on a content
    /// change — re-suggesting on every in-place slicer re-save would be exactly the
    /// suggestion-noise those heuristics are designed to avoid triggering repeatedly.
    private func reconcileKnownFile(_ row: SpoolFile, atURL url: URL) async throws -> ReconcileOutcome {
        guard let fileId = row.id else { return .unchanged }
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let diskSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let diskMtime = attrs[.modificationDate] as? Date ?? Date()

        let wasMissing = row.status == .missing
        let sizeChanged = diskSize != row.sizeBytes
        let mtimeChanged = row.mtime == nil || abs(diskMtime.timeIntervalSince(row.mtime!)) >= 1

        if !wasMissing, !sizeChanged, !mtimeChanged {
            try await writer.write { conn in
                try conn.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id = ?", arguments: [Date(), fileId])
            }
            return .unchanged
        }

        let newHash = (sizeChanged || mtimeChanged) ? try FileHasher.sha256Hex(ofFileAt: url) : row.contentHash

        if newHash != row.contentHash {
            let ext = row.ext.lowercased()
            // Matches IngestJobHandler's own ext-based dispatch, so a rehash and a
            // fresh ingest land on the same render_status/job-enqueue decision.
            let newStatus: FileRenderStatus = ModelExtension.noPreview.contains(ext) ? .unsupported : .pending
            try await writer.write { conn in
                try conn.execute(sql: """
                    UPDATE files SET
                        content_hash = ?, size_bytes = ?, mtime = ?,
                        status = 'active', last_seen_at = ?, render_status = ?,
                        thumbnail_path = NULL, bbox_x = NULL, bbox_y = NULL, bbox_z = NULL,
                        volume_mm3 = NULL, tri_count = NULL, is_manifold = NULL
                    WHERE id = ?
                    """, arguments: [newHash, diskSize, diskMtime, Date(), newStatus, fileId])
            }
            if ModelExtension.stepFormats.contains(ext) {
                try await enqueuer.enqueue(fileId: fileId, zipFileId: nil, jobType: .renderStep)
            } else if ModelExtension.fastRender.contains(ext) {
                try await enqueuer.enqueue(fileId: fileId, zipFileId: nil, jobType: .render)
            }
            return .rehashed
        }

        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE files SET size_bytes = ?, mtime = ?, status = 'active', last_seen_at = ? WHERE id = ?",
                arguments: [diskSize, diskMtime, Date(), fileId]
            )
        }
        return wasMissing ? .revived : .touched
    }

    /// Before treating a newly-discovered path as genuinely new, check whether its
    /// content matches a still-active row from this same root that this pass hasn't
    /// found at its recorded path yet — a real move candidate. Returns `nil` (caller
    /// falls through to normal new-file staging) if no such candidate exists.
    private func findMoveSource(sourceURL: URL, activeByHash: [String: [SpoolFile]], seenPaths: Set<String>) throws -> SpoolFile? {
        let hash = try FileHasher.sha256Hex(ofFileAt: sourceURL)
        guard let candidates = activeByHash[hash] else { return nil }
        return candidates.first { !seenPaths.contains($0.path) }
    }

    /// Re-points an existing file row to a new location — a rename/move keeps the same
    /// DB row (and therefore all its tags/relationships/project membership/print
    /// metadata, all keyed by file id, not path) instead of marking the old path
    /// missing and creating an unrelated new row for the new path. Content is unchanged
    /// by a pure move, so no re-hash/re-render is triggered.
    private func repoint(fileId: Int64, newRootId: Int64, newContainerURL: URL) async throws {
        let filename = newContainerURL.lastPathComponent
        let ext = newContainerURL.pathExtension.lowercased()
        try await writer.write { conn in
            try conn.execute(sql: """
                UPDATE files SET path = ?, filename = ?, ext = ?, watched_root_id = ?, status = 'active', last_seen_at = ?
                WHERE id = ?
                """, arguments: [newContainerURL.path, filename, ext, newRootId, Date(), fileId])
        }
    }

    /// Revives an already-known sidecar that was `missing` back to `active`, or stages a
    /// genuinely new one — mirrors the source app's identical two-way branch. Returns
    /// whether a revival happened (informational only; the source app doesn't track
    /// sidecar revivals as a distinct counter either).
    @discardableResult
    private func reconcileSidecar(atPath path: String, rootId: Int64, known: SidecarFile?) async throws -> Bool {
        if let known, known.status == .missing, let id = known.id {
            try await writer.write { conn in
                try conn.execute(sql: "UPDATE sidecar_files SET status = 'active' WHERE id = ?", arguments: [id])
            }
            return true
        }
        if known == nil {
            _ = try? await sidecars.stage(path: path, watchedRootId: rootId)
        }
        return false
    }
}
