import Foundation
import GRDB

/// Stages and looks up non-model "sidecar" files (README, preview photos, instruction
/// PDFs) that live alongside model files in a project folder — recorded for presence
/// only (filename/size), no hash, no render job, surfaced only on the owning project's
/// own page, never the main library grid.
public struct SidecarService: Sendable {
    /// A raster-image sidecar gets a thumbnail the same lightweight way SVG model
    /// files do — a plain copy, no rasterization needed since it's already an image.
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "bmp"]

    private let writer: any DatabaseWriter
    private let thumbnailsDirectory: URL?

    public init(writer: any DatabaseWriter, thumbnailsDirectory: URL?) {
        self.writer = writer
        self.thumbnailsDirectory = thumbnailsDirectory
    }

    /// Insert-or-ignore on the UNIQUE `path` column, so re-walking an already-known
    /// sidecar is a no-op. Returns the new sidecar's id, or `nil` if it was already
    /// known or couldn't be read.
    @discardableResult
    public func stage(path: String, watchedRootId: Int64) async throws -> Int64? {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0

        let sidecarId: Int64? = try await writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO sidecar_files (watched_root_id, path, filename, ext, size_bytes, first_seen_at, status)
                VALUES (?, ?, ?, ?, ?, ?, 'active')
                ON CONFLICT (path) DO NOTHING
                """, arguments: [watchedRootId, path, url.lastPathComponent, ext, sizeBytes, Date()])
            return conn.changesCount > 0 ? conn.lastInsertedRowID : nil
        }
        guard let sidecarId else { return nil }

        if let thumbnailsDirectory, Self.imageExtensions.contains(ext) {
            try? FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
            let thumbnailFilename = "sidecar-\(sidecarId).\(ext)"
            try? FileManager.default.copyItem(at: url, to: thumbnailsDirectory.appendingPathComponent(thumbnailFilename))
            try await writer.write { conn in
                try conn.execute(
                    sql: "UPDATE sidecar_files SET thumbnail_path = ? WHERE id = ?", arguments: [thumbnailFilename, sidecarId]
                )
            }
        }
        return sidecarId
    }

    /// Sidecars that live in the same folder as one of this project's confirmed member
    /// files — projects have no stored folder-path column of their own (only
    /// auto-created ones do, via `source_folder_path`), so this derives folder
    /// membership from the paths of files already linked to the project, matching
    /// every member's folder, not just the project's own tracked path.
    public func sidecars(inProjectId projectId: Int64) async throws -> [SidecarFile] {
        let filePaths = try await writer.read { conn in
            try String.fetchAll(conn, sql: """
                SELECT files.path FROM files
                JOIN project_files ON project_files.file_id = files.id
                WHERE project_files.project_id = ? AND project_files.status = 'confirmed' AND files.status = 'active'
                """, arguments: [projectId])
        }
        let dirs = Set(filePaths.map { ($0 as NSString).deletingLastPathComponent })
        guard !dirs.isEmpty else { return [] }

        let active = try await writer.read { conn in
            try SidecarFile.filter(Column("status") == SidecarStatus.active.rawValue).fetchAll(conn)
        }
        return active
            .filter { dirs.contains(($0.path as NSString).deletingLastPathComponent) }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
    }
}
