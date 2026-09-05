import Foundation

/// Moves a file from a `relocate_to_dropfolder` root into the drop folder, mirroring the
/// source app's `ingest.relocate`. Shared between `BackfillService` (new-file discovery)
/// and `RescanService` (new-file discovery during a periodic re-walk), since both call
/// into the same underlying "relocate before staging" step for a `.relocateToDropfolder`
/// root — exactly as the source app's `backfill.py` and `rescan.py` both import the same
/// `ingest.relocate` rather than each having their own copy.
enum FolderRelocation {
    /// A file sitting directly at the watched root (no containing folder at all) is
    /// relocated alone. Otherwise, the *entire top-level folder* it's found under —
    /// the direct child of the watched root, however many levels of subfolders and
    /// sidecar files sit between it and the actual model file — is moved as one unit.
    ///
    /// This used to only move the file's *immediate* parent, and only when that
    /// parent had no subdirectories of its own — deliberately not preserving full
    /// structure for "nested multi-level kits". Confirmed live that this was a real
    /// problem, not just a cosmetic scope limit: a Printables/Thingiverse-style
    /// download's model files almost always sit inside their own subfolder (e.g.
    /// `<Kit>/files/*.stl` next to `<Kit>/images/*.jpg`) — the old logic saw `files`
    /// as the leaf-with-no-subdirs and moved *that*, discarding the actually-
    /// meaningful `<Kit>` name entirely (`ProjectSuggestionService`'s own generic-
    /// container-name fallback had nowhere left to fall back *to*, since `files` now
    /// sat directly under the drop folder root with no parent) — hence real projects
    /// ending up named nothing but "files". It also left every sidecar (images,
    /// READMEs, licenses) behind in Downloads forever, since only the one leaf
    /// subfolder ever moved, not the kit's own top-level folder.
    ///
    /// Returns `nil` if a concurrent event (a sibling file under the same top-level
    /// folder) already relocated it — there's nothing left for this call to do.
    static func relocateFileOrFolder(sourceURL: URL, rootURL: URL, dropFolderRootURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        guard let topLevelFolder = topLevelAncestor(of: sourceURL, relativeTo: rootURL) else {
            return relocateSingleFile(sourceURL: sourceURL, dropFolderRootURL: dropFolderRootURL)
        }
        return relocateWholeFolder(topLevelFolder: topLevelFolder, sourceURL: sourceURL, dropFolderRootURL: dropFolderRootURL)
    }

    /// The direct child of `rootURL` that contains `fileURL` — the "package" boundary
    /// a single download almost always represents, regardless of how many subfolders
    /// it has inside. `nil` if `fileURL` sits directly at the root with no containing
    /// folder to preserve at all.
    ///
    /// Plain `NSString` path-component manipulation throughout, not `URL`'s own
    /// `.deletingLastPathComponent()`/`.standardizedFileURL` — confirmed live as a
    /// real bug: `.standardizedFileURL` silently drops the `/private` prefix from a
    /// `/private/var/...` path (the same `/var` symlink special-case documented
    /// elsewhere in this project), so comparing/counting components between a
    /// `.standardizedFileURL`-derived value and `fileURL`'s own un-touched path (as
    /// `relocateWholeFolder` below needs to, to reapply the relative path under the
    /// new location) silently drops one path segment too few.
    private static func topLevelAncestor(of fileURL: URL, relativeTo rootURL: URL) -> URL? {
        let rootPath = rootURL.path
        var currentPath = (fileURL.path as NSString).deletingLastPathComponent
        guard currentPath != rootPath else { return nil }
        while (currentPath as NSString).deletingLastPathComponent != rootPath {
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }
        return URL(fileURLWithPath: currentPath)
    }

    private static func relocateSingleFile(sourceURL: URL, dropFolderRootURL: URL) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        var destURL = dropFolderRootURL.appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destURL.path) {
            guard let hash = try? FileHasher.sha256Hex(ofFileAt: sourceURL) else { return nil }
            let suffix = String(hash.prefix(6))
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            let newName = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
            destURL = dropFolderRootURL.appendingPathComponent(newName)
        }
        do {
            try fileManager.moveItem(at: sourceURL, to: destURL)
        } catch {
            return nil // lost the race to a concurrent handler
        }
        return destURL
    }

    private static func relocateWholeFolder(topLevelFolder: URL, sourceURL: URL, dropFolderRootURL: URL) -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: topLevelFolder.path) else { return nil } // already relocated by a concurrent handler
        let destDir = uniquePath(base: dropFolderRootURL.appendingPathComponent(topLevelFolder.lastPathComponent))
        do {
            try fileManager.moveItem(at: topLevelFolder, to: destDir)
        } catch {
            return nil // lost the race to a concurrent handler for a sibling file
        }
        // `sourceURL` can be several levels below `topLevelFolder` (e.g.
        // `<Kit>/files/widget.stl`, with `topLevelFolder` == `<Kit>`) — reapply that
        // same relative path under the new location, not just the file's own bare
        // name, or the returned URL would point at a location that doesn't exist.
        // String-prefix-stripping, not `.pathComponents` counting — see
        // `topLevelAncestor`'s own comment for why mixing the two goes wrong.
        let relativePath = String(sourceURL.path.dropFirst(topLevelFolder.path.count))
        return URL(fileURLWithPath: destDir.path + relativePath)
    }

    /// Appends a numeric suffix (`Widget` -> `Widget (2)`) until `base` doesn't collide
    /// with something already there — used for whole-folder relocates, where a content
    /// hash (the per-file collision strategy above) doesn't make sense for a directory.
    private static func uniquePath(base: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: base.path) else { return base }
        var n = 2
        while true {
            let candidate = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) (\(n))")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
