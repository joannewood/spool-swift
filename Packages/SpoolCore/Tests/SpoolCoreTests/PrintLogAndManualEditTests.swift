import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct PrintLogAndManualEditTests {
    private func makeFile(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp", label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: root.id!, path: "/tmp/a.stl", filename: "a.stl", ext: "stl", sizeBytes: 1)
                .inserted(conn)
        }
        return file.id!
    }

    @Test func printLogUpsertCreatesAndUpdates() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let fileId = try await makeFile(db)
        let service = PrintLogService(writer: db.writer)

        try await service.upsert(fileId: fileId, printed: true, rating: 4, comments: "warped a bit")
        var log = try await service.fetch(fileId: fileId)
        #expect(log?.printed == true)
        #expect(log?.rating == 4)

        try await service.upsert(fileId: fileId, printed: true, rating: 5, comments: "perfect on retry")
        log = try await service.fetch(fileId: fileId)
        #expect(log?.rating == 5)
        #expect(log?.comments == "perfect on retry")
    }

    @Test func markingPrintedNeverTouchesPrintMetadataSource() async throws {
        // Regression for the exact reason print_log is a separate table: auto-extracted
        // metadata's source must survive a user marking the file printed.
        let db = try SQLiteSpoolDatabase(path: nil)
        let fileId = try await makeFile(db)
        let metadataService = PrintMetadataService(writer: db.writer)
        try await metadataService.upsertAutoExtracted(
            fileId: fileId, material: "PLA", printerProfile: nil, slicer: nil,
            settings: PrintSettings(), source: .autoExtracted3MF
        )

        let printLogService = PrintLogService(writer: db.writer)
        try await printLogService.upsert(fileId: fileId, printed: true, rating: 5, comments: nil)

        let metadata = try await db.writer.read { conn in try PrintMetadata.fetchOne(conn, key: fileId) }
        #expect(metadata?.source == .autoExtracted3MF, "print_log writes must never affect print_metadata.source")
    }

    @Test func manualEditAlwaysWinsAndSurvivesALaterAutoExtractionPass() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let fileId = try await makeFile(db)
        let service = PrintMetadataService(writer: db.writer)

        // Auto-extraction runs first (e.g. initial render)...
        try await service.upsertAutoExtracted(
            fileId: fileId, material: "PLA", printerProfile: "X1 Carbon", slicer: nil,
            settings: PrintSettings(nozzleDiameterMM: 0.4), source: .autoExtracted3MF
        )
        // ...user edits it manually...
        try await service.upsertManualEdit(fileId: fileId, material: "PETG (my override)", printerProfile: "X1 Carbon", slicer: nil, notes: "printed at 250C")
        // ...then a later rescan/re-render re-runs auto-extraction again.
        try await service.upsertAutoExtracted(
            fileId: fileId, material: "PLA", printerProfile: "X1 Carbon", slicer: nil,
            settings: PrintSettings(nozzleDiameterMM: 0.6), source: .autoExtracted3MF
        )

        let metadata = try await db.writer.read { conn in try PrintMetadata.fetchOne(conn, key: fileId) }
        #expect(metadata?.material == "PETG (my override)")
        #expect(metadata?.source == .manual)
        #expect(metadata?.notes == "printed at 250C")
    }

    @Test func manualEditDoesNotClearExistingStructuredSettings() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let fileId = try await makeFile(db)
        let service = PrintMetadataService(writer: db.writer)

        try await service.upsertAutoExtracted(
            fileId: fileId, material: "PLA", printerProfile: nil, slicer: nil,
            settings: PrintSettings(nozzleDiameterMM: 0.4), source: .autoExtracted3MF
        )
        try await service.upsertManualEdit(fileId: fileId, material: "PLA", printerProfile: nil, slicer: nil, notes: "great print")

        let metadata = try await db.writer.read { conn in try PrintMetadata.fetchOne(conn, key: fileId) }
        #expect(metadata?.settingsJson?.value.nozzleDiameterMM == 0.4, "manual edit form has no settings_json field, so it must leave it untouched")
    }
}
