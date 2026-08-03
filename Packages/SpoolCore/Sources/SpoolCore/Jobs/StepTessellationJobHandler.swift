import Foundation
import GRDB
import SpoolMesh

/// Dispatches a `renderStep` job (slow lane) by invoking the bundled OCCT `step-
/// tessellate` helper out-of-process — a crash or hang in OCCT can't take the app down
/// with it — then feeds the resulting STL through the exact same
/// `MeshAnalyzer.analyze()` + `ThumbnailRenderer.renderPNG()` pipeline `RenderJobHandler`
/// uses for STL/OBJ/3MF, via the same `STLParser` (the helper writes binary STL in
/// precisely the layout that parser expects).
public struct StepTessellationJobHandler: JobHandler {
    public enum HandlerError: Error {
        case missingFileId
        case converterFailed(exitCode: Int32, stderr: String)
    }

    private let writer: any DatabaseWriter
    private let thumbnailsDirectory: URL
    private let converterURL: URL?

    public init(writer: any DatabaseWriter, thumbnailsDirectory: URL, converterURL: URL? = StepConverterLocator.locate()) {
        self.writer = writer
        self.thumbnailsDirectory = thumbnailsDirectory
        self.converterURL = converterURL
    }

    public func handle(_ job: Job) async throws {
        guard let fileId = job.fileId else { throw HandlerError.missingFileId }
        guard let file = try await writer.read({ conn in try SpoolFile.fetchOne(conn, id: fileId) }) else { return }

        guard let converterURL else {
            // No bundled helper on this machine — same graceful "tracked/searchable/
            // taggable but never thumbnailed" treatment `.scad` already gets, not a
            // hard failure.
            try await markUnsupported(fileId: fileId)
            return
        }

        let tempSTL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).stl")
        defer { try? FileManager.default.removeItem(at: tempSTL) }

        do {
            try runConverter(converterURL: converterURL, input: URL(fileURLWithPath: file.path), output: tempSTL)
            let mesh = try STLParser.parse(url: tempSTL)
            let analysis = MeshAnalyzer.analyze(mesh)
            let pngData = try await MainActor.run { try ThumbnailRenderer.renderPNG(mesh: mesh) }
            let thumbnailPath = try writeThumbnail(pngData, fileId: fileId)
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
                    thumbnailPath, fileId,
                ])
            }
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

    private func runConverter(converterURL: URL, input: URL, output: URL) throws {
        let process = Process()
        process.executableURL = converterURL
        process.arguments = [input.path, output.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            throw HandlerError.converterFailed(
                exitCode: process.terminationStatus,
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
        }
    }

    private func writeThumbnail(_ data: Data, fileId: Int64) throws -> String {
        let filename = "\(fileId).png"
        try data.write(to: thumbnailsDirectory.appendingPathComponent(filename), options: .atomic)
        return filename
    }

    private func markUnsupported(fileId: Int64) async throws {
        try await writer.write { conn in
            try conn.execute(sql: "UPDATE files SET render_status = 'unsupported' WHERE id = ?", arguments: [fileId])
        }
    }
}
