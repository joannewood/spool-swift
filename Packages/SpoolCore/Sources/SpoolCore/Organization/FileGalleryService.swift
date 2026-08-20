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
    /// the time this does) for an image in the same folder whose base filename exactly
    /// matches this file's own, case-insensitively. A match becomes a `designerPhoto`
    /// slide and — since this only ever runs once per file, right after it's first
    /// staged — is auto-activated immediately, matching the mockup's "shown first,
    /// auto-selected — exact filename match" behavior. Idempotent: a rescan/re-ingest
    /// that revives an already-matched file is a no-op, not a second slide.
    public func matchDesignerPhoto(forFileId fileId: Int64, filePath: String) async throws {
        let fileURL = URL(fileURLWithPath: filePath)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let directory = fileURL.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        guard let match = entries.first(where: {
            $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(baseName) == .orderedSame
                && SidecarService.imageExtensions.contains($0.pathExtension.lowercased())
        }) else { return }

        let alreadyMatchedCount = try await writer.read { conn in
            try Int.fetchOne(
                conn, sql: "SELECT COUNT(*) FROM file_gallery_images WHERE file_id = ? AND source_path = ?",
                arguments: [fileId, match.path]
            ) ?? 0
        }
        guard alreadyMatchedCount == 0 else { return }

        _ = try await insertPhoto(fileId: fileId, sourceURL: match, kind: .designerPhoto, activateOnlyIfNoneActive: true)
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
