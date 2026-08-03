import Foundation
import GRDB

/// Upserts auto-extracted print metadata — the SQL `WHERE print_metadata.source !=
/// 'manual'` guard on the `DO UPDATE` clause is what makes this safe to call
/// unconditionally on every render: a row a user has manually edited (`source =
/// 'manual'`) is never silently overwritten by a later auto-extraction pass, matching
/// the source app's exact upsert behavior.
public struct PrintMetadataService: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func upsertAutoExtracted(
        fileId: Int64,
        material: String?,
        printerProfile: String?,
        slicer: String?,
        settings: PrintSettings,
        source: MetadataSource
    ) async throws {
        precondition(source != .manual, "manual edits go through a different code path")
        let settingsString = (try? JSONEncoder().encode(settings)).flatMap { String(data: $0, encoding: .utf8) }

        try await writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO print_metadata (file_id, material, printer_profile, slicer, settings_json, source)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET
                    material = excluded.material,
                    printer_profile = excluded.printer_profile,
                    slicer = excluded.slicer,
                    settings_json = excluded.settings_json,
                    source = excluded.source
                WHERE print_metadata.source != 'manual'
                """, arguments: [fileId, material, printerProfile, slicer, settingsString, source.rawValue])
        }
    }

    /// A user's own edit — always wins outright (no guard), and deliberately leaves
    /// `settings_json` untouched: that column is auto-extraction-only structured data
    /// (nozzle/layer-height/etc.), not something the manual material/printer/slicer/
    /// notes form edits.
    public func upsertManualEdit(fileId: Int64, material: String?, printerProfile: String?, slicer: String?, notes: String?) async throws {
        try await writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO print_metadata (file_id, material, printer_profile, slicer, notes, source)
                VALUES (?, ?, ?, ?, ?, 'manual')
                ON CONFLICT(file_id) DO UPDATE SET
                    material = excluded.material,
                    printer_profile = excluded.printer_profile,
                    slicer = excluded.slicer,
                    notes = excluded.notes,
                    source = 'manual'
                """, arguments: [fileId, material, printerProfile, slicer, notes])
        }
    }
}
