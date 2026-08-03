import Foundation
import GRDB

/// Three content-only heuristics run after a file is hashed, comparing it against
/// every other already-indexed active file — since both live ingest and backfill call
/// this per-file, every real pair gets caught the first time either member is the
/// "new" one, with no need to re-scan the whole library. All suggestions insert with
/// `status = 'suggested'` via insert-or-ignore against the `(from, to, type)` unique
/// index, so a user's manual confirm/reject is never silently overwritten by a later
/// pass.
public struct RelationshipSuggestionService: Sendable {
    private let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    public func suggestRelationships(forFileId fileId: Int64) async throws {
        guard let file = try await writer.read({ conn in try SpoolFile.fetchOne(conn, id: fileId) }),
              file.contentHash != nil else { return }

        let candidates = try await writer.read { conn in
            try SpoolFile
                .filter(Column("id") != fileId)
                .filter(Column("status") == FileStatus.active.rawValue)
                .fetchAll(conn)
        }

        for candidate in candidates {
            try await suggest(between: file, and: candidate)
        }
    }

    private func suggest(between file: SpoolFile, and candidate: SpoolFile) async throws {
        guard let fileId = file.id, let candidateId = candidate.id else { return }

        // duplicate_of: identical content hash — the strongest, most specific
        // signal, so a duplicate isn't also considered for the weaker heuristics below.
        // Unlike derived_from/new_version_of, "duplicate of" has no content-determined
        // direction, so the pair must be canonicalized (smaller id first) — otherwise
        // suggesting from A's side inserts (A,B) while a later suggest pass from B's
        // side inserts the distinct tuple (B,A), doubling up instead of deduping.
        if let hash = file.contentHash, hash == candidate.contentHash {
            let (canonicalFrom, canonicalTo) = fileId < candidateId ? (fileId, candidateId) : (candidateId, fileId)
            try await insertSuggestion(fromFileId: canonicalFrom, toFileId: canonicalTo, type: .duplicateOf, confidence: 1.0)
            return
        }

        let fileStem = stem(of: file.filename)
        let candidateStem = stem(of: candidate.filename)

        // derived_from: same basename, one side STEP and the other not — assumed
        // export direction is non-STEP derived from STEP.
        if fileStem == candidateStem {
            let fileIsStep = ModelExtension.stepFormats.contains(file.ext.lowercased())
            let candidateIsStep = ModelExtension.stepFormats.contains(candidate.ext.lowercased())
            if fileIsStep != candidateIsStep {
                let (stepId, otherId) = fileIsStep ? (fileId, candidateId) : (candidateId, fileId)
                try await insertSuggestion(fromFileId: otherId, toFileId: stepId, type: .derivedFrom, confidence: 0.6)
                return
            }
        }

        // new_version_of: same basename with a trailing _v<N>/-v<N> suffix stripped,
        // same extension, newer version number -> older.
        guard let fileVersion = versionInfo(of: file.filename), let candidateVersion = versionInfo(of: candidate.filename),
              fileVersion.base == candidateVersion.base,
              file.ext.lowercased() == candidate.ext.lowercased(),
              fileVersion.number != candidateVersion.number else { return }
        let (newerId, olderId) = fileVersion.number > candidateVersion.number ? (fileId, candidateId) : (candidateId, fileId)
        try await insertSuggestion(fromFileId: newerId, toFileId: olderId, type: .newVersionOf, confidence: 0.8)
    }

    private func insertSuggestion(fromFileId: Int64, toFileId: Int64, type: RelationshipType, confidence: Double) async throws {
        try await writer.write { conn in
            try conn.execute(sql: """
                INSERT INTO relationships (from_file_id, to_file_id, type, status, confidence, created_at)
                VALUES (?, ?, ?, 'suggested', ?, ?)
                ON CONFLICT (from_file_id, to_file_id, type) DO NOTHING
                """, arguments: [fromFileId, toFileId, type.rawValue, confidence, Date()])
        }
    }

    private func stem(of filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    private static let versionSuffixRegex = try? NSRegularExpression(pattern: #"^(.*)[-_][vV](\d+)$"#)

    private func versionInfo(of filename: String) -> (base: String, number: Int)? {
        let name = stem(of: filename)
        guard let regex = Self.versionSuffixRegex else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let baseRange = Range(match.range(at: 1), in: name),
              let numberRange = Range(match.range(at: 2), in: name),
              let number = Int(name[numberRange]) else { return nil }
        return (String(name[baseRange]), number)
    }
}
