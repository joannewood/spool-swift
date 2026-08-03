import Foundation
import GRDB
import SpoolMesh

/// Dispatches a `render` job (fast lane — everything except STEP) by extension to the
/// right SpoolMesh loader, runs mesh analysis, renders a thumbnail, and writes the
/// results back to the file's row.
public struct RenderJobHandler: JobHandler {
    public enum RenderError: Error {
        case missingFileId
        case unsupportedExtension(String)
    }

    private let writer: any DatabaseWriter
    private let thumbnailsDirectory: URL
    private let metadataService: PrintMetadataService

    public init(writer: any DatabaseWriter, thumbnailsDirectory: URL) {
        self.writer = writer
        self.thumbnailsDirectory = thumbnailsDirectory
        self.metadataService = PrintMetadataService(writer: writer)
    }

    public func handle(_ job: Job) async throws {
        guard let fileId = job.fileId else { throw RenderError.missingFileId }
        guard let file = try await writer.read({ conn in try SpoolFile.fetchOne(conn, id: fileId) }) else { return }

        // Deliberately independent of render success — a 3MF rejected by the
        // mesh-safety guards (or any other render failure) must still get its Bambu
        // metadata, since nothing about `Metadata/project_settings.config`/
        // `slice_info.config` depends on the mesh data at all.
        try? await extractMetadataIfApplicable(file: file)

        do {
            try await render(file: file)
        } catch {
            try? await writer.write { conn in
                try conn.execute(
                    sql: "UPDATE files SET render_status = 'failed', render_error = ? WHERE id = ?",
                    arguments: ["\(error)", fileId]
                )
            }
            throw error
        }
    }

    private func extractMetadataIfApplicable(file: SpoolFile) async throws {
        let url = URL(fileURLWithPath: file.path)
        switch file.ext.lowercased() {
        case "3mf":
            guard let metadata = try BambuMetadataExtractor.extract(threeMFAt: url) else { return }
            try await metadataService.upsertAutoExtracted(
                fileId: file.id!,
                material: metadata.material,
                printerProfile: metadata.printerModel,
                // Always "Bambu Studio" once project_settings.config is present at
                // all — not read from the file, matching the source app's literal.
                slicer: "Bambu Studio",
                settings: PrintSettings(
                    nozzleDiameterMM: metadata.nozzleDiameterMM,
                    layerHeightMM: metadata.layerHeightMM,
                    infillPercent: metadata.infillPercent,
                    filamentUsedGrams: metadata.filamentUsedGrams,
                    estimatedPrintMinutes: metadata.estimatedPrintMinutes,
                    slicerVersion: metadata.slicerVersion
                ),
                source: .autoExtracted3MF
            )
        case "gcode":
            guard let metadata = try GcodeMetadataExtractor.extract(url: url) else { return }
            try await metadataService.upsertAutoExtracted(
                fileId: file.id!,
                material: metadata.material,
                printerProfile: metadata.printerModel,
                slicer: metadata.slicerVersion,
                settings: PrintSettings(
                    nozzleDiameterMM: metadata.nozzleDiameterMM,
                    layerHeightMM: metadata.layerHeightMM,
                    infillPercent: metadata.infillPercent,
                    filamentUsedGrams: metadata.filamentUsedGrams,
                    estimatedPrintMinutes: metadata.estimatedPrintMinutes,
                    slicerVersion: metadata.slicerVersion
                ),
                source: .autoExtractedGcode
            )
        default:
            return
        }
    }

    private func render(file: SpoolFile) async throws {
        let url = URL(fileURLWithPath: file.path)
        switch file.ext.lowercased() {
        case "stl":
            try await renderMeshBased(file: file, mesh: STLParser.parse(url: url))
        case "obj":
            try await renderMeshBased(file: file, mesh: OBJLoader.parse(url: url))
        case "3mf":
            try await renderMeshBased(file: file, mesh: ThreeMFReader.read(url: url))
        case "svg":
            try copySVGThumbnail(file: file, sourceURL: url)
            try await markDone(fileId: file.id!, thumbnailPath: "\(file.id!).svg")
        case "gcode":
            if let pngData = try GcodeThumbnailExtractor.extractLargestThumbnail(url: url) {
                let path = try writeThumbnail(pngData, fileId: file.id!)
                try await markDone(fileId: file.id!, thumbnailPath: path)
            } else {
                // No embedded thumbnail is a normal, expected outcome (an opt-in
                // slicer-profile setting) — not an error, matching the source app's
                // treatment of a gcode with no thumbnail block.
                try await markDone(fileId: file.id!, thumbnailPath: nil)
            }
        default:
            throw RenderError.unsupportedExtension(file.ext)
        }
    }

    private func renderMeshBased(file: SpoolFile, mesh: TriangleMesh) async throws {
        let analysis = MeshAnalyzer.analyze(mesh)
        let pngData = try await MainActor.run { try ThumbnailRenderer.renderPNG(mesh: mesh) }
        let thumbnailPath = try writeThumbnail(pngData, fileId: file.id!)
        try await writer.write { conn in
            try conn.execute(sql: """
                UPDATE files SET
                    bbox_x = ?, bbox_y = ?, bbox_z = ?,
                    volume_mm3 = ?, tri_count = ?, is_manifold = ?,
                    thumbnail_path = ?, render_status = 'done', render_error = NULL
                WHERE id = ?
                """, arguments: [
                Double(analysis.boundingBoxMax.x - analysis.boundingBoxMin.x),
                Double(analysis.boundingBoxMax.y - analysis.boundingBoxMin.y),
                Double(analysis.boundingBoxMax.z - analysis.boundingBoxMin.z),
                analysis.volumeMm3, analysis.triangleCount, analysis.isManifold,
                thumbnailPath, file.id,
            ])
        }
    }

    private func copySVGThumbnail(file: SpoolFile, sourceURL: URL) throws {
        let dest = thumbnailsDirectory.appendingPathComponent("\(file.id!).svg")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: sourceURL, to: dest)
    }

    private func writeThumbnail(_ data: Data, fileId: Int64) throws -> String {
        let filename = "\(fileId).png"
        try data.write(to: thumbnailsDirectory.appendingPathComponent(filename), options: .atomic)
        return filename
    }

    private func markDone(fileId: Int64, thumbnailPath: String?) async throws {
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE files SET render_status = 'done', render_error = NULL, thumbnail_path = ? WHERE id = ?",
                arguments: [thumbnailPath, fileId]
            )
        }
    }
}
