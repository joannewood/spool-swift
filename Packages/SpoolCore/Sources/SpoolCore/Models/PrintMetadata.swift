import GRDB

/// Structured fields extracted from a Bambu 3MF (`project_settings.config` +
/// `slice_info.config`) or a Prusa-lineage gcode footer — stored as JSON in
/// `print_metadata.settings_json`, matching the source app's `settings_json` jsonb
/// column. Search's structured-metadata phrase matching ("0.2mm nozzle") reads these
/// fields with a small numeric tolerance rather than exact equality.
public struct PrintSettings: Codable, Sendable, Equatable {
    public var nozzleDiameterMM: Double?
    public var layerHeightMM: Double?
    public var infillPercent: Double?
    public var filamentUsedGrams: Double?
    public var estimatedPrintMinutes: Double?
    public var slicerVersion: String?

    public init(
        nozzleDiameterMM: Double? = nil,
        layerHeightMM: Double? = nil,
        infillPercent: Double? = nil,
        filamentUsedGrams: Double? = nil,
        estimatedPrintMinutes: Double? = nil,
        slicerVersion: String? = nil
    ) {
        self.nozzleDiameterMM = nozzleDiameterMM
        self.layerHeightMM = layerHeightMM
        self.infillPercent = infillPercent
        self.filamentUsedGrams = filamentUsedGrams
        self.estimatedPrintMinutes = estimatedPrintMinutes
        self.slicerVersion = slicerVersion
    }
}

/// One row per file (PK = file_id). Auto-extraction (`source != .manual`) must never
/// clobber a manual edit — enforced by the upsert's `WHERE source != 'manual'` guard in
/// the ingestion layer, not by a DB constraint, mirroring the source app exactly.
public struct PrintMetadata: SpoolRecord, Sendable {
    public static let databaseTableName = "print_metadata"

    public var fileId: Int64
    public var material: String?
    public var printerProfile: String?
    public var slicer: String?
    public var settingsJson: JSONColumn<PrintSettings>?
    public var notes: String?
    public var source: MetadataSource

    public init(
        fileId: Int64,
        material: String? = nil,
        printerProfile: String? = nil,
        slicer: String? = nil,
        settingsJson: PrintSettings? = nil,
        notes: String? = nil,
        source: MetadataSource = .manual
    ) {
        self.fileId = fileId
        self.material = material
        self.printerProfile = printerProfile
        self.slicer = slicer
        self.settingsJson = settingsJson.map(JSONColumn.init)
        self.notes = notes
        self.source = source
    }
}

/// Deliberately separate from `PrintMetadata` — see the source app's rationale in
/// CLAUDE.md: folding "printed" tracking into print_metadata would make marking a file
/// printed silently block future auto-extraction (both would share `source`), and a
/// shared `notes`/`comments` field name on one page is a real form-collision footgun.
public struct PrintLog: SpoolRecord, Sendable {
    public static let databaseTableName = "print_log"

    public var fileId: Int64
    public var printed: Bool
    public var rating: Int?
    public var comments: String?

    public init(fileId: Int64, printed: Bool = false, rating: Int? = nil, comments: String? = nil) {
        self.fileId = fileId
        self.printed = printed
        self.rating = rating
        self.comments = comments
    }
}
