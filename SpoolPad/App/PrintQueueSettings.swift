import Foundation

/// Persisted configuration for sending a file to the Saddle & STEM print queue — either
/// directly to the Ranch machine (when this iPad is physically there, on the Ranch's own
/// network) or through a classroom's relay machine (when it isn't; the relay forwards to
/// the Ranch over Tailscale, see `print-manager/classroom-relay`). Both are the same
/// `POST /api/submissions` contract the browser capture extension already uses — just a
/// different URL and bearer token per destination.
///
/// URLs aren't secret (same spirit as the capture extension's own settings popup) so they
/// live in `UserDefaults`; the two bearer tokens are real per-device secrets and live only
/// in the Keychain, never `UserDefaults`, never written to a file.
///
/// Deliberately holds no student name — these iPads are shared/passed around between
/// students, so that's entered fresh on every send instead (see `SendToPrintQueueView`),
/// not stored here for reuse.
@MainActor
final class PrintQueueSettings: ObservableObject {
    enum Endpoint: String, CaseIterable, Identifiable {
        case ranch
        case relay

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .ranch: return "Ranch (direct)"
            case .relay: return "Classroom Relay"
            }
        }
    }

    private enum Keys {
        static let ranchURL = "printQueue.ranchURL"
        static let relayURL = "printQueue.relayURL"
        static let lastSuccessfulEndpoint = "printQueue.lastSuccessfulEndpoint"
        static let ranchTokenKeychainKey = "ranchToken"
        static let relayTokenKeychainKey = "relayToken"
    }

    @Published var ranchURL: String {
        didSet { UserDefaults.standard.set(ranchURL, forKey: Keys.ranchURL) }
    }
    @Published var relayURL: String {
        didSet { UserDefaults.standard.set(relayURL, forKey: Keys.relayURL) }
    }
    @Published var ranchToken: String {
        didSet { Keychain.set(ranchToken, forKey: Keys.ranchTokenKeychainKey) }
    }
    @Published var relayToken: String {
        didSet { Keychain.set(relayToken, forKey: Keys.relayTokenKeychainKey) }
    }

    /// Whichever endpoint last actually accepted a submission — tried first next time so
    /// a send doesn't eat the unreachable-endpoint timeout on every single attempt, only
    /// when the situation actually changed (e.g. the iPad moved since the last send).
    var lastSuccessfulEndpoint: Endpoint? {
        get {
            UserDefaults.standard.string(forKey: Keys.lastSuccessfulEndpoint).flatMap(Endpoint.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue?.rawValue, forKey: Keys.lastSuccessfulEndpoint)
        }
    }

    init() {
        ranchURL = UserDefaults.standard.string(forKey: Keys.ranchURL) ?? ""
        relayURL = UserDefaults.standard.string(forKey: Keys.relayURL) ?? ""
        ranchToken = Keychain.get(Keys.ranchTokenKeychainKey) ?? ""
        relayToken = Keychain.get(Keys.relayTokenKeychainKey) ?? ""
    }

    func url(for endpoint: Endpoint) -> URL? {
        let raw: String
        switch endpoint {
        case .ranch: raw = ranchURL
        case .relay: raw = relayURL
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed)
    }

    func token(for endpoint: Endpoint) -> String {
        switch endpoint {
        case .ranch: return ranchToken
        case .relay: return relayToken
        }
    }

    /// Try order for a send attempt: whichever endpoint is configured, starting with
    /// `lastSuccessfulEndpoint` if that one's still configured, then the other.
    var candidateOrder: [Endpoint] {
        let configured = Endpoint.allCases.filter { url(for: $0) != nil }
        guard let last = lastSuccessfulEndpoint, let index = configured.firstIndex(of: last) else {
            return configured
        }
        var ordered = configured
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }
}
