import Foundation

/// Moves a file from a `relocate_to_dropfolder` root into the drop folder, mirroring the
/// source app's `ingest.relocate`. Shared between `BackfillService` (new-file discovery)
/// and `RescanService` (new-file discovery during a periodic re-walk), since both call
/// into the same underlying "relocate before staging" step for a `.relocateToDropfolder`
/// root — exactly as the source app's `backfill.py` and `rescan.py` both import the same
/// `ingest.relocate` rather than each having their own copy.
enum FolderRelocation {
    /// A file sitting directly at the watched root (no meaningful parent folder), or
    /// whose parent folder itself contains subdirectories (deliberate scope limit —
    /// nested multi-level kits don't get full structure preservation), is relocated
    /// alone. Otherwise the file's parent is a leaf folder, and the whole folder is
    /// moved as a unit, carrying sidecars along for free. Returns `nil` if a concurrent
    /// event (a sibling file in the same folder) already relocated it — there's nothing
    /// left for this call to do.
    static func relocateFileOrFolder(sourceURL: URL, rootURL: URL, dropFolderRootURL: URL) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        let parentDir = sourceURL.deletingLastPathComponent()
        let isRootLevel = parentDir.standardizedFileURL.path == rootURL.standardizedFileURL.path
        if !isRootLevel {
            var isDir: ObjCBool = false
            let parentExists = fileManager.fileExists(atPath: parentDir.path, isDirectory: &isDir)
            if parentExists, isDir.boolValue {
                let siblings = (try? fileManager.contentsOfDirectory(
                    at: parentDir, includingPropertiesForKeys: [.isDirectoryKey]
                )) ?? []
                let hasSubdirs = siblings.contains {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                }
                if !hasSubdirs {
                    return relocateWholeFolder(parentDir: parentDir, sourceURL: sourceURL, dropFolderRootURL: dropFolderRootURL)
                }
            }
        }
        return relocateSingleFile(sourceURL: sourceURL, dropFolderRootURL: dropFolderRootURL)
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

    private static func relocateWholeFolder(parentDir: URL, sourceURL: URL, dropFolderRootURL: URL) -> URL? {
        let fileManager = FileManager.default
        let destDir = uniquePath(base: dropFolderRootURL.appendingPathComponent(parentDir.lastPathComponent))
        do {
            try fileManager.moveItem(at: parentDir, to: destDir)
        } catch {
            return nil // lost the race to a concurrent handler for a sibling file
        }
        return destDir.appendingPathComponent(sourceURL.lastPathComponent)
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
