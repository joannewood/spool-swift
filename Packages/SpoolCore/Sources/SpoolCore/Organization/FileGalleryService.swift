import Foundation
import GRDB

/// The file detail page's thumbnail gallery: a rendered mesh thumbnail plus any
/// auto-matched "designer photo" or user-uploaded slides, with one active at a time.
///
/// `files.thumbnail_path` stays the single source of truth every other view (grid
/// cards, list rows, project cards, search results) already reads directly — every
/// mutation here keeps it in sync with whichever `file_gallery_images` row is active,
/// specifically so none of those existing views needed to change for this feature.
///
/// A native-app addition designed from a mockup the source app posted for feedback
/// (GitHub issue #9 there) but never actually built — there is no real Python
/// implementation to port; this is a fresh design matching that mockup's intent
/// (`docs/mockups/issue-9-thumbnail-gallery.png` in the source repo): a designer photo
/// with an exact filename match is auto-selected over the render, "Use as thumbnail"
/// switches the active slide, and uploading a photo both adds and activates it
/// immediately.
public struct FileGalleryService: Sendable {
    public enum GalleryError: Error {
        case cannotDeleteRenderedThumbnail
        case noThumbnailsDirectory
    }

    private let writer: any DatabaseWriter
    private let thumbnailsDirectory: URL?

    /// Always sorts after every photo slide — nothing else needs `sortOrder` to mean
    /// more than "roughly discovery/upload order, with the render always trailing."
    private static let renderedSortOrder = 1_000_000

    public init(writer: any DatabaseWriter, thumbnailsDirectory: URL?) {
        self.writer = writer
        self.thumbnailsDirectory = thumbnailsDirectory
    }

    public func images(forFileId fileId: Int64) async throws -> [FileGalleryImage] {
        try await writer.read { conn in
            try FileGalleryImage.fetchAll(
                conn, sql: "SELECT * FROM file_gallery_images WHERE file_id = ? ORDER BY sort_order, created_at",
                arguments: [fileId]
            )
        }
    }

    /// Called from `RenderJobHandler` on every successful render (including a
    /// re-render). Replaces this file's one `rendered` slide outright — there's only
    /// ever one — but only takes over as the *active* slide if nothing else is active
    /// yet (a brand-new file with no designer-photo match). A re-render must never
    /// steal activation away from a photo the user (or the ingest-time auto-match)
    /// already chose; only the slide's own image changes underneath it.
    public func recordRenderedThumbnail(fileId: Int64, thumbnailPath: String) async throws {
        try await writer.write { conn in
            try conn.execute(sql: "DELETE FROM file_gallery_images WHERE file_id = ? AND kind = 'rendered'", arguments: [fileId])
            let rendered = try FileGalleryImage(
                fileId: fileId, kind: .rendered, thumbnailPath: thumbnailPath, sortOrder: Self.renderedSortOrder
            ).inserted(conn)
            try conn.execute(
                sql: "UPDATE files SET active_gallery_image_id = ?, thumbnail_path = ? WHERE id = ? AND active_gallery_image_id IS NULL",
                arguments: [rendered.id, thumbnailPath, fileId]
            )
        }
    }

    /// Called once from `IngestJobHandler`, best-effort, for every newly-staged model
    /// file: looks (directly on disk, not via the `sidecar_files` table — that table's
    /// own staging pass runs independently and isn't guaranteed to have already run by
    /// the time this does) for candidate designer photos in two places:
    ///
    /// 1. **The same folder**, by exact base-filename match (`Widget.stl` +
    ///    `Widget.jpg`) — the original, most specific signal.
    /// 2. **A sibling `images/` folder** one level down — the other half of the
    ///    Printables/Thingiverse download convention this project already accounts
    ///    for elsewhere (model files in one place, preview photos in an adjacent
    ///    `images/` folder). If this model is the *only* model file in its folder,
    ///    every photo in `images/` unambiguously belongs to it, named-match or not —
    ///    added as its own slide each. If it shares the folder with other model files
    ///    (a multi-part kit), only a filename match inside `images/` is safe to
    ///    attribute to this specific one, to avoid pinning an unrelated part's photo
    ///    onto the wrong file.
    ///
    /// A match becomes a `designerPhoto` slide; only the first one ever inserted for
    /// a file is auto-activated (matching the mockup's "shown first, auto-selected"
    /// behavior for a single photo) — this only ever runs once per file, right after
    /// it's first staged, so later candidates in the same call just become additional
    /// browsable slides. Idempotent per source image: a rescan/re-ingest that revives
    /// an already-matched file never re-adds the same photo as a second slide.
    public func matchDesignerPhoto(forFileId fileId: Int64, filePath: String) async throws {
        let fileURL = URL(fileURLWithPath: filePath)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }

        var candidates: [URL] = []
        if let sameFolderMatch = imageMatching(baseName: baseName, in: entries) {
            candidates.append(sameFolderMatch)
        }

        if let imagesFolder = entries.first(where: {
            $0.lastPathComponent.caseInsensitiveCompare("images") == .orderedSame
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
        }), let imageEntries = try? fileManager.contentsOfDirectory(at: imagesFolder, includingPropertiesForKeys: nil) {
            let images = imageEntries.filter { SidecarService.imageExtensions.contains($0.pathExtension.lowercased()) }
            if isOnlyModelFile(in: entries) {
                candidates.append(contentsOf: images)
            } else if let nameMatch = imageMatching(baseName: baseName, in: images) {
                candidates.append(nameMatch)
            }
        }
        guard !candidates.isEmpty else { return }

        for candidate in candidates {
            let alreadyMatchedCount = try await writer.read { conn in
                try Int.fetchOne(
                    conn, sql: "SELECT COUNT(*) FROM file_gallery_images WHERE file_id = ? AND source_path = ?",
                    arguments: [fileId, candidate.path]
                ) ?? 0
            }
            guard alreadyMatchedCount == 0 else { continue }
            // `activateOnlyIfNoneActive: true` on every call, not just the first —
            // its own DB-level guard (`active_gallery_image_id IS NULL`) means only
            // whichever candidate actually lands first takes over, so this loop
            // doesn't need to track that itself.
            _ = try await insertPhoto(fileId: fileId, sourceURL: candidate, kind: .designerPhoto, activateOnlyIfNoneActive: true)
        }
    }

    private func imageMatching(baseName: String, in entries: [URL]) -> URL? {
        entries.first {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(baseName) == .orderedSame
                && SidecarService.imageExtensions.contains($0.pathExtension.lowercased())
        }
    }

    private func isOnlyModelFile(in entries: [URL]) -> Bool {
        entries.filter { ModelExtension.all.contains($0.pathExtension.lowercased()) }.count == 1
    }

    /// The file detail page's "+ Upload a photo" flow — adds a new slide and makes it
    /// active immediately, matching the mockup's "Upload & use" behavior exactly (no
    /// separate "use as thumbnail" click needed right after uploading).
    @discardableResult
    public func upload(fileId: Int64, sourceURL: URL) async throws -> FileGalleryImage {
        try await insertPhoto(fileId: fileId, sourceURL: sourceURL, kind: .uploaded, activateOnlyIfNoneActive: false)
    }

    /// The mockup's "Use as thumbnail" button — switches the active slide without
    /// touching the gallery's contents at all.
    public func setActive(fileId: Int64, imageId: Int64) async throws {
        try await writer.write { conn in
            guard let image = try FileGalleryImage.fetchOne(conn, id: imageId), image.fileId == fileId else { return }
            try conn.execute(
                sql: "UPDATE files SET active_gallery_image_id = ?, thumbnail_path = ? WHERE id = ?",
                arguments: [imageId, image.thumbnailPath, fileId]
            )
        }
    }

    /// Removes a designer-photo or uploaded slide — not in the mockup, but a gallery
    /// with no way to remove a bad upload felt incomplete. The rendered slide can
    /// never be deleted this way (it isn't a user's data to remove — it's just
    /// whatever the mesh renderer currently produces). If the deleted slide was the
    /// active one, falls back to the rendered thumbnail (always present once a render
    /// has ever succeeded) rather than leaving a dangling active pointer or a blank
    /// thumbnail everywhere else in the app.
    public func delete(imageId: Int64, fileId: Int64) async throws {
        let deletedThumbnailPath = try await writer.write { conn -> String? in
            guard let image = try FileGalleryImage.fetchOne(conn, id: imageId), image.fileId == fileId else { return nil }
            guard image.kind != .rendered else { throw GalleryError.cannotDeleteRenderedThumbnail }
            try image.delete(conn)
            let file = try SpoolFile.fetchOne(conn, id: fileId)
            if file?.thumbnailPath == image.thumbnailPath {
                let rendered = try FileGalleryImage
                    .filter(Column("file_id") == fileId && Column("kind") == GalleryImageKind.rendered.rawValue)
                    .fetchOne(conn)
                try conn.execute(
                    sql: "UPDATE files SET active_gallery_image_id = ?, thumbnail_path = ? WHERE id = ?",
                    arguments: [rendered?.id, rendered?.thumbnailPath, fileId]
                )
            }
            return image.thumbnailPath
        }
        // Best-effort — the DB delete above already succeeded regardless of whether
        // the on-disk thumbnail file cleanup does.
        if let deletedThumbnailPath, let thumbnailsDirectory {
            try? FileManager.default.removeItem(at: thumbnailsDirectory.appendingPathComponent(deletedThumbnailPath))
        }
    }

    /// Copies `sourceURL` into the thumbnails directory under a fresh UUID-based name
    /// *before* touching the database — if the copy fails, nothing is left behind in
    /// an inconsistent state (a gallery row pointing at a thumbnail that doesn't
    /// exist), unlike an insert-then-copy order would risk.
    @discardableResult
    private func insertPhoto(
        fileId: Int64, sourceURL: URL, kind: GalleryImageKind, activateOnlyIfNoneActive: Bool
    ) async throws -> FileGalleryImage {
        guard let thumbnailsDirectory else { throw GalleryError.noThumbnailsDirectory }
        let ext = sourceURL.pathExtension.lowercased()
        let thumbnailFilename = "gallery-\(UUID().uuidString).\(ext)"
        try FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: thumbnailsDirectory.appendingPathComponent(thumbnailFilename))

        let sortOrder = try await nextPhotoSortOrder(fileId: fileId)
        return try await writer.write { conn in
            let image = try FileGalleryImage(
                fileId: fileId, kind: kind, thumbnailPath: thumbnailFilename,
                sourcePath: sourceURL.path, label: sourceURL.lastPathComponent, sortOrder: sortOrder
            ).inserted(conn)
            let condition = activateOnlyIfNoneActive ? "AND active_gallery_image_id IS NULL" : ""
            try conn.execute(
                sql: "UPDATE files SET active_gallery_image_id = ?, thumbnail_path = ? WHERE id = ? \(condition)",
                arguments: [image.id, thumbnailFilename, fileId]
            )
            return image
        }
    }

    private func nextPhotoSortOrder(fileId: Int64) async throws -> Int {
        try await writer.read { conn in
            let maxOrder = try Int.fetchOne(
                conn, sql: "SELECT MAX(sort_order) FROM file_gallery_images WHERE file_id = ? AND kind != 'rendered'",
                arguments: [fileId]
            ) ?? nil
            return (maxOrder ?? -1) + 1
        }
    }
}
