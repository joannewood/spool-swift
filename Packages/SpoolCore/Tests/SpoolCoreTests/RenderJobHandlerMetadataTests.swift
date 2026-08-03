import Foundation
import GRDB
import SpoolMesh
import Testing
import ZIPFoundation
@testable import SpoolCore

/// Confirms the specific requirement called out in the project plan: a 3MF rejected by
/// the mesh-safety guards must still get its Bambu metadata, since nothing about
/// `Metadata/project_settings.config` depends on the mesh data.
@Suite struct RenderJobHandlerMetadataTests {
    private func addEntry(_ archive: Archive, path: String, contents: String) throws {
        let data = Data(contents.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }

    @Test func metadataSurvivesAMeshSafetyRejection() async throws {
        // A model.model with far more <component> tags than the safety guard allows —
        // this must fail rendering, but the sibling Metadata/project_settings.config
        // must still be extracted.
        var componentsXML = ""
        for _ in 0...ThreeMFReader.SafetyLimits.maxItemComponentTags {
            componentsXML += "<component objectid=\"1\"/>\n"
        }
        let modelXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
              <resources>
                <object id="1" type="model">
                  <mesh><vertices><vertex x="0" y="0" z="0"/></vertices><triangles></triangles></mesh>
                </object>
                <object id="2" type="model"><components>\(componentsXML)</components></object>
              </resources>
              <build><item objectid="2"/></build>
            </model>
            """
        let projectSettings = """
            {"nozzle_diameter": ["0.4"], "printer_model": "X1 Carbon"}
            """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("RenderJobHandlerMetadataTests-\(UUID().uuidString).3mf")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        try addEntry(archive, path: "3D/3dmodel.model", contents: modelXML)
        try addEntry(archive, path: "Metadata/project_settings.config", contents: projectSettings)

        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp", label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: root.id!, path: url.path, filename: url.lastPathComponent, ext: "3mf", sizeBytes: 1)
                .inserted(conn)
        }

        let thumbsDir = FileManager.default.temporaryDirectory.appendingPathComponent("thumbs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: thumbsDir) }

        let handler = RenderJobHandler(writer: db.writer, thumbnailsDirectory: thumbsDir)
        await #expect(throws: (any Error).self) {
            try await handler.handle(Job(fileId: file.id, jobType: .render))
        }

        let updatedFile = try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: file.id!) }
        #expect(updatedFile?.renderStatus == .failed, "the component-count guard must still reject this file")

        let metadata = try await db.writer.read { conn in try PrintMetadata.fetchOne(conn, key: file.id!) }
        #expect(metadata != nil, "metadata extraction must run independently of render success")
        #expect(metadata?.printerProfile == "X1 Carbon")
        #expect(metadata?.source == .autoExtracted3MF)
        #expect(metadata?.slicer == "Bambu Studio", "always this literal once project_settings.config is present at all")
    }
}
