import Foundation
import GRDB

/// Walks a watched root's real folder tree and stages any not-yet-known model file,
/// enqueuing an `ingest` job for each — the native equivalent of the source app's
/// startup backfill walk. Safe to call repeatedly: `files.path` is `UNIQUE`, so an
/// already-known path is skipped rather than re-staged. Also peeks any `.zip`/`.7z`/
/// `.rar` encountered in the same walk (via `ArchiveInspectionService`) — sharing one
/// tree traversal for both concerns, rather than walking the whole root twice.
public actor BackfillService {
    private static let archiveExtensions: Set<String> = ["zip", "7z", "rar"]

    private let writer: any DatabaseWriter
    private let enqueuer: any JobEnqueuer
    private let archiveInspection: ArchiveInspectionService
    private let sidecars: SidecarService
    private let fileManager = FileManager.default

    /// `thumbnailsDirectory` is optional so tests that don't care about sidecar image
    /// thumbnails can omit it — sidecar presence is still staged either way, just
    /// without a thumbnail copy for image sidecars.
    public init(
        writer: any DatabaseWriter,
        enqueuer: any JobEnqueuer,
        thumbnailsDirectory: URL? = nil,
        externalArchiveToolURL: URL? = nil
    ) {
        self.writer = writer
        self.enqueuer = enqueuer
        self.archiveInspection = ArchiveInspectionService(writer: writer, enqueuer: enqueuer, externalToolURL: externalArchiveToolURL)
        self.sidecars = SidecarService(writer: writer, thumbnailsDirectory: thumbnailsDirectory)
    }

    /// - Parameters:
    ///   - root: the `watched_roots` row (must already be persisted, i.e. `id != nil`).
    ///   - rootURL: the resolved, security-scope-accessible URL for this root (from
    ///     `RootAccessManager`) — walking `root.hostPath` directly would not be under
    ///     an active security scope.
    ///   - dropFolderRoot: the active drop-folder root + its resolved URL, required only
    ///     when `root.ingestMode == .relocateToDropfolder` (a `downloads`-kind root
    ///     whose files must be physically moved into the drop folder before indexing,
    ///     rather than indexed in place). `nil` for an `.indexInPlace` root.
    /// - Returns: how many new model files were staged (archives aren't counted here —
    ///   they're a separate review flow, not something that "shows up" in the library).
    @discardableResult
    public func run(
        root: WatchedRoot,
        rootURL: URL,
        dropFolderRoot: (root: WatchedRoot, url: URL)? = nil
    ) async throws -> Int {
        guard let rootId = root.id else { return 0 }
        let knownPaths = try await writer.read { conn in
            try Set(String.fetchAll(
                conn, sql: "SELECT path FROM files WHERE watched_root_id = ?", arguments: [rootId]
            ))
        }

        var staged = 0
        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        // Materialized into an array before any relocation happens — moving a whole leaf
        // folder mid-walk (see `relocateFileOrFolder` below) could otherwise disrupt
        // `FileManager.enumerator`'s still-in-progress traversal of that same tree,
        // mirroring the source app's identical `list(_walk_project_folders(...))` guard.
        var discovered: [URL] = []
        while let url = enumerator?.nextObject() as? URL { discovered.append(url) }

        for url in discovered {
            guard !JunkFilter.isIgnorable(url.lastPathComponent) else { continue }
            // A single unreadable/racy file (iCloud eviction, a transient deadlock, a
            // file a sibling's folder-relocate already carried away) must never abort
            // the whole root's walk — matching a real production incident in the
            // source app where one bad file crashed backfill entirely and, under
            // auto-restart, reliably re-crashed on the same file forever. Skipping it
            // here just means it's picked up on the next backfill/rescan pass.
            do {
                let values = try url.resourceValues(
                    forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                )
                if values.isDirectory == true { continue }

                let ext = url.pathExtension.lowercased()
                if Self.archiveExtensions.contains(ext) {
                    try? await archiveInspection.inspect(path: url.path, watchedRootId: rootId)
                    continue
                }

                guard ModelExtension.all.contains(ext) else {
                    // Sidecars ride along with whatever the model files in this folder
                    // do — a relocate-mode root's sidecars either already moved with
                    // their folder or will be discovered at their new home once that
                    // folder shows up in the drop folder's own walk.
                    if root.ingestMode != .relocateToDropfolder {
                        _ = try? await sidecars.stage(path: url.path, watchedRootId: rootId)
                    }
                    continue
                }

                var stageURL = url
                var stageRootId = rootId
                if root.ingestMode == .relocateToDropfolder, let dropFolderRoot, let dropFolderRootId = dropFolderRoot.root.id {
                    guard let relocated = try FolderRelocation.relocateFileOrFolder(
                        sourceURL: url, rootURL: rootURL, dropFolderRootURL: dropFolderRoot.url
                    ) else {
                        continue // a sibling file's event already relocated the whole folder
                    }
                    stageURL = relocated
                    stageRootId = dropFolderRootId
                } else {
                    guard !knownPaths.contains(url.path) else { continue }
                }

                let stub = SpoolFile(
                    watchedRootId: stageRootId,
                    path: stageURL.path,
                    filename: stageURL.lastPathComponent,
                    ext: ext,
                    sizeBytes: Int64(values.fileSize ?? 0),
                    mtime: values.contentModificationDate
                )
                let inserted = try await writer.write { conn in try stub.inserted(conn) }
                try await enqueuer.enqueue(fileId: inserted.id, zipFileId: nil, jobType: .ingest)
                staged += 1
            } catch {
                continue
            }
        }
        return staged
    }

    /// Stages one specific path if it's a recognized, not-yet-known model file (or
    /// peeks it if it's an archive) — the live-watch equivalent of one iteration of
    /// `run`'s walk, used when a settled FSEvents path should be handled immediately
    /// rather than waiting for the next full re-walk. Deliberately a separate per-file
    /// DB lookup rather than sharing `run`'s batched `knownPaths` set — that batching is
    /// what makes a full walk over thousands of files cheap, but would be the wrong
    /// tradeoff for a single path.
    ///
    /// - Parameters:
    ///   - root / rootURL: the watched root this path was seen under, and its resolved
    ///     URL — needed (not just the id) so a `.relocateToDropfolder` root can relocate
    ///     the file exactly as `run` does, rather than indexing it in place.
    ///   - dropFolderRoot: required only when `root.ingestMode == .relocateToDropfolder`.
    @discardableResult
    public func stageIfNew(
        path: String,
        root: WatchedRoot,
        rootURL: URL,
        dropFolderRoot: (root: WatchedRoot, url: URL)? = nil
    ) async throws -> Bool {
        guard let watchedRootId = root.id else { return false }
        let url = URL(fileURLWithPath: path)
        guard !JunkFilter.isIgnorable(url.lastPathComponent) else { return false }
        let ext = url.pathExtension.lowercased()

        if Self.archiveExtensions.contains(ext) {
            try await archiveInspection.inspect(path: path, watchedRootId: watchedRootId)
            return false
        }
        guard ModelExtension.all.contains(ext) else {
            if root.ingestMode != .relocateToDropfolder {
                _ = try? await sidecars.stage(path: path, watchedRootId: watchedRootId)
            }
            return false
        }

        var stageURL = url
        var stageRootId = watchedRootId
        if root.ingestMode == .relocateToDropfolder, let dropFolderRoot, let dropFolderRootId = dropFolderRoot.root.id {
            guard let relocated = try FolderRelocation.relocateFileOrFolder(
                sourceURL: url, rootURL: rootURL, dropFolderRootURL: dropFolderRoot.url
            ) else {
                return false // a sibling file's event already relocated the whole folder
            }
            stageURL = relocated
            stageRootId = dropFolderRootId
        } else {
            let alreadyKnown = try await writer.read { conn in
                try SpoolFile.filter(Column("path") == path).fetchCount(conn) > 0
            }
            guard !alreadyKnown else { return false }
        }

        guard let attrs = try? fileManager.attributesOfItem(atPath: stageURL.path) else { return false }
        let stub = SpoolFile(
            watchedRootId: stageRootId,
            path: stageURL.path,
            filename: stageURL.lastPathComponent,
            ext: ext,
            sizeBytes: (attrs[.size] as? NSNumber)?.int64Value ?? 0,
            mtime: attrs[.modificationDate] as? Date
        )
        let inserted = try await writer.write { conn in try stub.inserted(conn) }
        try await enqueuer.enqueue(fileId: inserted.id, zipFileId: nil, jobType: .ingest)
        return true
    }
}
