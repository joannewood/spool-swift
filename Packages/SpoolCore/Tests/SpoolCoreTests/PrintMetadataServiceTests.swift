import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct PrintMetadataServiceTests {
    private func makeFile(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp", label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: root.id!, path: "/tmp/a.3mf", filename: "a.3mf", ext: "3mf", sizeBytes: 1)
                .inserted(conn)
        }
        return file.id!
    }

    @Test func upsertCreatesAndUpdatesAnAutoExtractedRow() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let fileId = try await makeFile(db)
        let service = PrintMetadataService(writer: db.writer)

        try await service.upsertAutoExtracted(
            fileId: fileId, material: "PLA", printerProfile: "X1 Carbon", slicer: nil,
            settings: PrintSettings(nozzleDiameterMM: 0.4), source: .autoExtracted3MF
        )
        var row = try await db.writer.read { conn in try PrintMetadata.fetchOne(conn, key: fileId) }
        #expect(row?.material == "PLA")
        #expect(row?.source == .autoExtracted3MF)
        #expect(row?.settingsJson?.value.nozzleDiameterMM == 0.4)

        // A later re-extraction (e.g. a rescan) updates the row in place.
        try await service.upsertAutoExtracted(
            fileId: fileId, material: "PETG", printerProfile: "X1 Carbon", slicer: nil,
            settings: PrintSettings(nozzleDiameterMM: 0.6), source: .autoExtracted3MF
        )
        row = try await db.writer.read { conn in try PrintMetadata.fetchOne(conn, key: fileId) }
        #expect(row?.material == "PETG")
        #expect(row?.settingsJson?.value.nozzleDiameterMM == 0.6)
    }

    @Test func manualEditIsNeverClobberedByAutoExtraction() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let fileId = try await makeFile(db)

        let manual = PrintMetadata(fileId: fileId, material: "Manually Set PLA", source: .manual)
        _ = try await db.writer.write { conn in try manual.inserted(conn) }

        let service = PrintMetadataService(writer: db.writer)
        try await service.upsertAutoExtracted(
            fileId: fileId, material: "Auto Extracted PETG", printerProfile: nil, slicer: nil,
            settings: PrintSettings(), source: .autoExtracted3MF
        )

        let row = try await db.writer.read { conn in try PrintMetadata.fetchOne(conn, key: fileId) }
        #expect(row?.material == "Manually Set PLA", "auto-extraction must never overwrite a manual edit")
        #expect(row?.source == .manual)
    }
}
