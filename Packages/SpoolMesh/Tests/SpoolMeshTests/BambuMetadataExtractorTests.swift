import Foundation
import Testing
import ZIPFoundation
@testable import SpoolMesh

private func addEntry(_ archive: Archive, path: String, contents: String) throws {
    let data = Data(contents.utf8)
    try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
        data.subdata(in: Int(position)..<Int(position) + size)
    }
}

private func makeThreeMFFile(projectSettingsJSON: String?, sliceInfoXML: String?) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolMeshTests-\(UUID().uuidString).3mf")
    let archive = try Archive(url: url, accessMode: .create)
    try addEntry(archive, path: "3D/3dmodel.model", contents: "<model></model>")
    if let projectSettingsJSON {
        try addEntry(archive, path: "Metadata/project_settings.config", contents: projectSettingsJSON)
    }
    if let sliceInfoXML {
        try addEntry(archive, path: "Metadata/slice_info.config", contents: sliceInfoXML)
    }
    return url
}

private let realProjectSettings = """
{
    "nozzle_diameter": ["0.4"],
    "layer_height": "0.2",
    "sparse_infill_density": "15%",
    "printer_model": "Bambu Lab X1 Carbon",
    "filament_type": ["PLA", "PETG", "TPU", "ABS"]
}
"""

private let realSliceInfo = """
<?xml version="1.0" encoding="UTF-8"?>
<config>
    <header>
        <header_item key="X-BBL-Client-Version" value="01.09.00.11"/>
    </header>
    <plate>
        <metadata key="index" value="1"/>
        <metadata key="weight" value="15.73"/>
        <metadata key="prediction" value="3720"/>
        <filament id="1" type="PLA" color="#FFFFFF" used_g="15.73"/>
    </plate>
</config>
"""

@Suite struct BambuMetadataExtractorTests {
    @Test func extractsFullMetadataFromARealBambuExportShape() throws {
        let url = try makeThreeMFFile(projectSettingsJSON: realProjectSettings, sliceInfoXML: realSliceInfo)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try #require(try BambuMetadataExtractor.extract(threeMFAt: url))
        #expect(metadata.nozzleDiameterMM == 0.4)
        #expect(metadata.layerHeightMM == 0.2)
        #expect(metadata.infillPercent == 15)
        #expect(metadata.printerModel == "Bambu Lab X1 Carbon")
        // Material comes from slice_info's actually-used filament, NOT the
        // project_settings filament_type array (which lists every configured AMS slot).
        #expect(metadata.material == "PLA")
        #expect(metadata.filamentColor == "#FFFFFF")
        #expect(metadata.filamentUsedGrams == 15.73)
        #expect(metadata.estimatedPrintMinutes == 62) // 3720s / 60
        #expect(metadata.slicerVersion == "01.09.00.11")
    }

    @Test func ignoresMeshContentSizeOrShape() throws {
        // Metadata extraction never reads 3D/*.model at all — a mesh entry that would
        // fail mesh-safety's guards must have zero effect on metadata parsing, since
        // the render step and metadata extraction are entirely independent passes.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolMeshTests-\(UUID().uuidString).3mf")
        defer { try? FileManager.default.removeItem(at: url) }
        let archive = try Archive(url: url, accessMode: .create)
        try addEntry(archive, path: "3D/Objects/object_1.model", contents: String(repeating: "x", count: 1_000_000))
        try addEntry(archive, path: "Metadata/project_settings.config", contents: #"{"printer_model": "Bambu Lab H2D"}"#)

        let metadata = try #require(try BambuMetadataExtractor.extract(threeMFAt: url))
        #expect(metadata.printerModel == "Bambu Lab H2D")
    }

    @Test func returnsNilWhenProjectSettingsConfigIsAbsent() throws {
        // A plain (non-Bambu) 3MF — no Metadata/project_settings.config at all.
        let url = try makeThreeMFFile(projectSettingsJSON: nil, sliceInfoXML: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try BambuMetadataExtractor.extract(threeMFAt: url)
        #expect(metadata == nil)
    }

    @Test func stillReturnsProcessSettingsWhenSliceInfoIsMissing() throws {
        let url = try makeThreeMFFile(projectSettingsJSON: realProjectSettings, sliceInfoXML: nil)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = try #require(try BambuMetadataExtractor.extract(threeMFAt: url))
        #expect(metadata.nozzleDiameterMM == 0.4)
        #expect(metadata.material == nil)
        #expect(metadata.filamentUsedGrams == nil)
    }
}
