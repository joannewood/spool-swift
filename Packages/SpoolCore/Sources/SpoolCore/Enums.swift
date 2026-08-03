import GRDB

public enum RootKind: String, Codable, DatabaseValueConvertible, Sendable {
    case library
    case dropFolder = "drop_folder"
    case downloads
}

/// A Finder-label-style flag color for a project — a native-app addition (not in the
/// source app). Every project defaults to `.blue`; a project given any other color
/// sorts to the top of the sidebar tree and cards list (see
/// `ProjectService.allProjects`/`projectSummaries`).
public enum ProjectColor: String, Codable, DatabaseValueConvertible, Sendable, CaseIterable {
    case blue, red, orange, yellow, green, purple, gray
}

public enum RootIngestMode: String, Codable, DatabaseValueConvertible, Sendable {
    case indexInPlace = "index_in_place"
    case relocateToDropfolder = "relocate_to_dropfolder"
}

public enum FileStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case active
    case missing
}

/// `unsupported` is a native-app addition (not in the source Postgres enum) — used for
/// formats that are tracked/searchable but deliberately never rendered (STEP until M5, .scad).
public enum FileRenderStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case pending
    case rendering
    case done
    case failed
    case unsupported
}

public enum RelationshipType: String, Codable, DatabaseValueConvertible, Sendable {
    case derivedFrom = "derived_from"
    case newVersionOf = "new_version_of"
    case variantOf = "variant_of"
    case duplicateOf = "duplicate_of"
}

public enum SuggestionStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case suggested
    case confirmed
    case rejected
}

public enum MetadataSource: String, Codable, DatabaseValueConvertible, Sendable {
    case manual
    case autoExtracted3MF = "auto_extracted_3mf"
    case autoExtractedGcode = "auto_extracted_gcode"
}

public enum JobType: String, Codable, DatabaseValueConvertible, Sendable {
    case ingest
    case render
    case renderStep = "render_step"
    case rescan
    case extractZip = "extract_zip"

    /// Fast lane: everything except CAD tessellation, matching the source app's
    /// `worker` (JOB_TYPES=ingest,render,extract_zip) container.
    public static let fastLane: Set<JobType> = [.ingest, .render, .rescan, .extractZip]
    /// Slow lane: matches the source app's dedicated `worker-step` container,
    /// so a STEP backlog can never block quick mesh renders.
    public static let slowLane: Set<JobType> = [.renderStep]
}

public enum JobStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case queued
    case running
    case done
    case failed
}

/// `unsupportedFormat` is a native-app addition — used when a 7z/rar archive is found
/// but no system extraction tool (unar/7z) is available, rather than crashing or
/// silently ignoring it.
public enum ZipStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case suggested
    case confirmed
    case rejected
    case unsupportedFormat = "unsupported_format"
}

public enum SidecarStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case active
    case missing
}
