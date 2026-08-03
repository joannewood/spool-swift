import GRDB

/// Executes one queued unit of work. Implementations live outside SpoolCore (ingestion,
/// rendering, etc. — later milestones) and are wired in via `JobHandlers` so the queue
/// itself has no knowledge of what a "render" job actually does.
public protocol JobHandler: Sendable {
    func handle(_ job: Job) async throws
}

/// One handler per `JobType`, dispatched by `JobWorkerLane`.
public struct JobHandlers: Sendable {
    public var ingest: any JobHandler
    public var render: any JobHandler
    public var renderStep: any JobHandler
    public var rescan: any JobHandler
    public var extractZip: any JobHandler

    public init(
        ingest: any JobHandler,
        render: any JobHandler,
        renderStep: any JobHandler,
        rescan: any JobHandler,
        extractZip: any JobHandler
    ) {
        self.ingest = ingest
        self.render = render
        self.renderStep = renderStep
        self.rescan = rescan
        self.extractZip = extractZip
    }

    func handler(for type: JobType) -> any JobHandler {
        switch type {
        case .ingest: return ingest
        case .render: return render
        case .renderStep: return renderStep
        case .rescan: return rescan
        case .extractZip: return extractZip
        }
    }
}

/// Does nothing successfully — placeholder wiring for job types a milestone hasn't
/// implemented yet, so `JobQueue` can be stood up and tested (M0) before the real
/// ingestion/render handlers exist (M1+).
public struct NoOpJobHandler: JobHandler {
    public init() {}
    public func handle(_ job: Job) async throws {}
}

/// STEP/STP tessellation (via bundled OpenCASCADE) is its own late milestone (M5) —
/// see the project plan. Until then, `render_step` jobs land here and mark the file
/// `render_status = 'unsupported'`, the same graceful "tracked/searchable/taggable but
/// never thumbnailed" treatment the source app gives `.scad` for a different reason.
public struct UnsupportedFormatJobHandler: JobHandler {
    public enum HandlerError: Error {
        case missingFileId
    }

    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func handle(_ job: Job) async throws {
        guard let fileId = job.fileId else { throw HandlerError.missingFileId }
        try await writer.write { conn in
            try conn.execute(
                sql: "UPDATE files SET render_status = 'unsupported' WHERE id = ?", arguments: [fileId]
            )
        }
    }
}
