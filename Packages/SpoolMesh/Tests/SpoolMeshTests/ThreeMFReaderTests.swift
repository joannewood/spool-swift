import Foundation
import Testing
import ZIPFoundation
@testable import SpoolMesh

private func makeCubeModelXML(objectId: Int = 1) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
      <resources>
        <object id="\(objectId)" type="model">
          <mesh>
            <vertices>
              <vertex x="0" y="0" z="0"/>
              <vertex x="1" y="0" z="0"/>
              <vertex x="1" y="1" z="0"/>
              <vertex x="0" y="1" z="0"/>
              <vertex x="0" y="0" z="1"/>
              <vertex x="1" y="0" z="1"/>
              <vertex x="1" y="1" z="1"/>
              <vertex x="0" y="1" z="1"/>
            </vertices>
            <triangles>
              <triangle v1="0" v2="3" v3="2"/>
              <triangle v1="0" v2="2" v3="1"/>
              <triangle v1="4" v2="5" v3="6"/>
              <triangle v1="4" v2="6" v3="7"/>
              <triangle v1="0" v2="1" v3="5"/>
              <triangle v1="0" v2="5" v3="4"/>
              <triangle v1="1" v2="2" v3="6"/>
              <triangle v1="1" v2="6" v3="5"/>
              <triangle v1="2" v2="3" v3="7"/>
              <triangle v1="2" v2="7" v3="6"/>
              <triangle v1="3" v2="0" v3="4"/>
              <triangle v1="3" v2="4" v3="7"/>
            </triangles>
          </mesh>
        </object>
      </resources>
      <build>
        <item objectid="\(objectId)"/>
      </build>
    </model>
    """
}

/// Writes a real `.3mf` (a genuine zip archive) to a temp file with the given
/// `3D/3dmodel.model` contents, so tests exercise the actual zip + XML pipeline rather
/// than a mocked reader.
private func makeThreeMFFile(modelXML: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolMeshTests-\(UUID().uuidString).3mf")
    let archive = try Archive(url: url, accessMode: .create)
    let data = Data(modelXML.utf8)
    try archive.addEntry(
        with: "3D/3dmodel.model", type: .file, uncompressedSize: Int64(data.count)
    ) { position, size in
        data.subdata(in: Int(position)..<Int(position) + size)
    }
    return url
}

@Suite struct ThreeMFReaderTests {
    @Test func readsSingleObjectCubeViaBuildItem() throws {
        let url = try makeThreeMFFile(modelXML: makeCubeModelXML())
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFReader.read(url: url)
        #expect(mesh.vertices.count == 8)
        #expect(mesh.triangles.count == 12)

        let analysis = MeshAnalyzer.analyze(mesh)
        #expect(analysis.isManifold == true)
    }

    @Test func resolvesComponentReferenceWithTranslation() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1" type="model">
              <mesh>
                <vertices>
                  <vertex x="0" y="0" z="0"/>
                  <vertex x="1" y="0" z="0"/>
                  <vertex x="0" y="1" z="0"/>
                </vertices>
                <triangles>
                  <triangle v1="0" v2="1" v3="2"/>
                </triangles>
              </mesh>
            </object>
            <object id="2" type="model">
              <components>
                <component objectid="1" transform="1 0 0 0 1 0 0 0 1 10 20 30"/>
              </components>
            </object>
          </resources>
          <build>
            <item objectid="2"/>
          </build>
        </model>
        """
        let url = try makeThreeMFFile(modelXML: xml)
        defer { try? FileManager.default.removeItem(at: url) }

        let mesh = try ThreeMFReader.read(url: url)
        #expect(mesh.vertices.count == 3)
        // The component's transform translates by (10, 20, 30).
        #expect(mesh.vertices[0] == SIMD3<Float>(10, 20, 30))
        #expect(mesh.vertices[1] == SIMD3<Float>(11, 20, 30))
        #expect(mesh.vertices[2] == SIMD3<Float>(10, 21, 30))
    }

    @Test func oversizedModelEntryIsRejectedBeforeDecompression() throws {
        // Genuinely exceeds the 12MB guard when uncompressed.
        let paddedXML = makeCubeModelXML() + String(repeating: " ", count: ThreeMFReader.SafetyLimits.maxUncompressedModelBytes)
        let url = try makeThreeMFFile(modelXML: paddedXML)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ThreeMFReader.ThreeMFError.self) {
            _ = try ThreeMFReader.read(url: url)
        }
    }

    @Test func tooManyComponentReferencesIsRejected() throws {
        var componentsXML = ""
        // One more than the limit — each is a real <component> tag the parser counts.
        for _ in 0...ThreeMFReader.SafetyLimits.maxItemComponentTags {
            componentsXML += "<component objectid=\"1\"/>\n"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1" type="model">
              <mesh>
                <vertices><vertex x="0" y="0" z="0"/></vertices>
                <triangles></triangles>
              </mesh>
            </object>
            <object id="2" type="model">
              <components>
                \(componentsXML)
              </components>
            </object>
          </resources>
          <build><item objectid="2"/></build>
        </model>
        """
        let url = try makeThreeMFFile(modelXML: xml)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ThreeMFReader.ThreeMFError.self) {
            _ = try ThreeMFReader.read(url: url)
        }
    }

    @Test func cyclicComponentReferenceIsRejectedRatherThanHanging() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1" type="model">
              <components><component objectid="2"/></components>
            </object>
            <object id="2" type="model">
              <components><component objectid="1"/></components>
            </object>
          </resources>
          <build><item objectid="1"/></build>
        </model>
        """
        let url = try makeThreeMFFile(modelXML: xml)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ThreeMFReader.ThreeMFError.self) {
            _ = try ThreeMFReader.read(url: url)
        }
    }

    @Test func oversizedNonRootModelEntryIsRejected() throws {
        // The oversized content lives in a secondary `3D/Objects/*.model` entry, not the
        // root `3D/3dmodel.model` — the size guard must still catch it via the summed
        // total across every `3D/*.model` entry, matching the original's
        // `test_check_3mf_mesh_size_rejects_oversized_mesh`.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolMeshTests-\(UUID().uuidString).3mf")
        let archive = try Archive(url: url, accessMode: .create)
        let rootData = Data(makeCubeModelXML().utf8)
        try archive.addEntry(with: "3D/3dmodel.model", type: .file, uncompressedSize: Int64(rootData.count)) { position, size in
            rootData.subdata(in: Int(position)..<Int(position) + size)
        }
        let paddedData = Data(String(repeating: " ", count: ThreeMFReader.SafetyLimits.maxUncompressedModelBytes).utf8)
        try archive.addEntry(with: "3D/Objects/object_1.model", type: .file, uncompressedSize: Int64(paddedData.count)) { position, size in
            paddedData.subdata(in: Int(position)..<Int(position) + size)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ThreeMFReader.ThreeMFError.self) {
            _ = try ThreeMFReader.read(url: url)
        }
    }

    @Test func componentCountSumsAcrossModelEntries() throws {
        // Tags split across the root model and a secondary `3D/Objects/*.model` entry —
        // neither one alone exceeds the limit, but their sum does. Matches the
        // original's `test_check_3mf_component_count_sums_across_model_entries`.
        let half = ThreeMFReader.SafetyLimits.maxItemComponentTags / 2 + 1
        func componentsBlock() -> String {
            var xml = ""
            for _ in 0..<half { xml += "<component objectid=\"1\"/>\n" }
            return xml
        }
        let rootXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="1" type="model">
              <mesh><vertices><vertex x="0" y="0" z="0"/></vertices><triangles></triangles></mesh>
            </object>
            <object id="2" type="model">
              <components>\(componentsBlock())</components>
            </object>
          </resources>
          <build><item objectid="2"/></build>
        </model>
        """
        let objectXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
          <resources>
            <object id="3" type="model">
              <components>\(componentsBlock())</components>
            </object>
          </resources>
        </model>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolMeshTests-\(UUID().uuidString).3mf")
        let archive = try Archive(url: url, accessMode: .create)
        let rootData = Data(rootXML.utf8)
        try archive.addEntry(with: "3D/3dmodel.model", type: .file, uncompressedSize: Int64(rootData.count)) { position, size in
            rootData.subdata(in: Int(position)..<Int(position) + size)
        }
        let objectData = Data(objectXML.utf8)
        try archive.addEntry(with: "3D/Objects/object_1.model", type: .file, uncompressedSize: Int64(objectData.count)) { position, size in
            objectData.subdata(in: Int(position)..<Int(position) + size)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ThreeMFReader.ThreeMFError.self) {
            _ = try ThreeMFReader.read(url: url)
        }
    }

    @Test func missingModelEntryThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolMeshTests-\(UUID().uuidString).3mf")
        let archive = try Archive(url: url, accessMode: .create)
        let data = Data("irrelevant".utf8)
        try archive.addEntry(with: "not-the-model.txt", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ThreeMFReader.ThreeMFError.self) {
            _ = try ThreeMFReader.read(url: url)
        }
    }
}
