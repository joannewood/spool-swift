import Foundation
import GRDB

/// Hashes a freshly-staged file and dispatches the next job, mirroring the source
/// app's ingest→hash→render split (a live-watched file is staged with `contentHash =
/// nil` before this ever runs). `.scad` deliberately never gets a render job — same
/// "no preview, not a stuck job" treatment the source app gives it, since a real
/// preview would mean running arbitrary OpenSCAD scripts.
public struct IngestJobHandler: JobHandler {
    public enum IngestError: Error {
        case missingFileId
    }

    private let writer: any DatabaseWriter
    private let enqueuer: any JobEnqueuer
    private let relationshipSuggestions: RelationshipSuggestionService
    private let projectSuggestions: ProjectSuggestionService

    public init(writer: any DatabaseWriter, enqueuer: any JobEnqueuer) {
        self.writer = writer
        self.enqueuer = enqueuer
        self.relationshipSuggestions = RelationshipSuggestionService(writer: writer)
        self.projectSuggestions = ProjectSuggestionService(writer: writer)
    }

    public func handle(_ job: Job) async throws {
        guard let fileId = job.fileId else { throw IngestError.missingFileId }
        guard var file = try await writer.read({ conn in try SpoolFile.fetchOne(conn, id: fileId) }) else {
            // Row vanished (e.g. deleted) between enqueue and claim — nothing to do.
            return
        }

        let url = URL(fileURLWithPath: file.path)
        file.contentHash = try FileHasher.sha256Hex(ofFileAt: url)
        file.mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        file.lastSeenAt = Date()

        let ext = file.ext.lowercased()
        if ModelExtension.noPreview.contains(ext) {
            file.renderStatus = .unsupported
        }

        let updated = file
        try await writer.write { conn in try updated.update(conn) }

        // Best-effort: a suggestion-heuristic hiccup must never block the file from
        // getting its render job.
        try? await relationshipSuggestions.suggestRelationships(forFileId: fileId)
        try? await projectSuggestions.suggestProject(forFileId: fileId)

        if ModelExtension.stepFormats.contains(ext) {
            try await enqueuer.enqueue(fileId: fileId, zipFileId: nil, jobType: .renderStep)
        } else if ModelExtension.fastRender.contains(ext) {
            try await enqueuer.enqueue(fileId: fileId, zipFileId: nil, jobType: .render)
        }
    }
}
