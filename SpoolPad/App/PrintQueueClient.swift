import Foundation

/// Talks to the Saddle & STEM print queue's `POST /api/submissions` — the same JSON
/// contract the Chrome capture extension and classroom-relay forwarder already use (see
/// `print-manager/print-queue/app/main.py`'s `SubmissionIn`), so no server-side changes
/// were needed for this. A submission from here just looks like one more platform.
enum PrintQueueClient {
    /// Matches the server's own `MAX_INLINE_FILE_BYTES` — checked here too so a student
    /// gets a clear "too big" message before spending time base64-encoding and uploading
    /// a file the server would reject anyway.
    static let maxInlineFileBytes = 50 * 1024 * 1024

    enum SendError: LocalizedError {
        case noEndpointsConfigured
        case fileTooLarge(bytes: Int)
        case unauthorized
        case serverError(status: Int, message: String)
        case networkError(String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .noEndpointsConfigured:
                return "No print queue server is set up yet. Ask your teacher to add one in Settings."
            case .fileTooLarge(let bytes):
                let mb = Double(bytes) / 1024 / 1024
                return String(format: "This file is %.0fMB — too large to send (50MB limit). Ask your teacher for help.", mb)
            case .unauthorized:
                return "The print queue didn't accept this iPad's access token. Ask your teacher to check Settings."
            case .serverError(let status, let message):
                return "The print queue said \(status): \(message.isEmpty ? "no details" : message)"
            case .networkError(let message):
                return message
            case .invalidResponse:
                return "The print queue sent back something unexpected."
            }
        }
    }

    private struct SubmissionPayload: Encodable {
        var source_url: String
        var source_platform: String
        var title: String
        var student_name: String
        var notes: String?
        var source_file_base64: String
        var source_file_name: String
    }

    private struct SubmissionResponse: Decodable {
        var id: Int
    }

    /// A short, cheap reachability check against the unauthenticated `GET /api/colors` —
    /// reused as-is rather than adding a dedicated health-check route, since this already
    /// exists for the capture extension's own "Test connection" button. A short timeout
    /// (not the default ~60s) is the whole point: this is what lets a send attempt fail
    /// fast against an unreachable Ranch and fall back to the relay instead of hanging.
    static func probe(url: URL, timeout: TimeInterval = 2.5) async -> Bool {
        var request = URLRequest(url: url.appendingPathComponent("api/colors"))
        request.timeoutInterval = timeout
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Reads `fileURL`'s bytes, base64-encodes them, and posts a submission to
    /// `endpointURL`. `sourceIdentifier` fills `source_url` — there's no real source URL
    /// for a file a student designed/owns locally, so callers pass a synthetic
    /// `spoolpad://` one instead, just to satisfy the column (`NOT NULL`, not otherwise
    /// validated — see main.py's schema).
    static func submit(
        fileURL: URL,
        fileName: String,
        title: String,
        studentName: String,
        notes: String,
        sourceIdentifier: String,
        endpointURL: URL,
        token: String,
        timeout: TimeInterval = 30
    ) async throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw SendError.networkError("Couldn't read the file on this iPad: \(error.localizedDescription)")
        }
        guard data.count <= maxInlineFileBytes else {
            throw SendError.fileTooLarge(bytes: data.count)
        }

        let payload = SubmissionPayload(
            source_url: sourceIdentifier,
            source_platform: "spoolpad",
            title: title,
            student_name: studentName,
            notes: notes.isEmpty ? nil : notes,
            source_file_base64: data.base64EncodedString(),
            source_file_name: fileName
        )

        var request = URLRequest(url: endpointURL.appendingPathComponent("api/submissions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)

        let response: URLResponse
        let responseData: Data
        do {
            (responseData, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SendError.networkError("Couldn't reach the print queue: \(error.localizedDescription)")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SendError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 201:
            guard let decoded = try? JSONDecoder().decode(SubmissionResponse.self, from: responseData) else {
                throw SendError.invalidResponse
            }
            return decoded.id
        case 401:
            throw SendError.unauthorized
        default:
            let message = String(data: responseData, encoding: .utf8) ?? ""
            throw SendError.serverError(status: httpResponse.statusCode, message: String(message.prefix(200)))
        }
    }
}
