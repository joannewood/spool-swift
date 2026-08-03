import Foundation

/// Ports the source app's "wait for 3 consecutive stable size checks, 0.4s apart"
/// copy-in-progress guard — a file mid-copy/mid-download must not be ingested/hashed
/// before it's actually finished writing. One shared tick drives every pending path
/// (an actor-scoped timer), rather than one `Timer` per dirty file, so a burst of many
/// files landing at once (e.g. an unzipped kit) doesn't proliferate timers.
public actor SettlementTracker {
    public struct Stat: Equatable, Sendable {
        public let size: Int64
        public let modificationDate: Date?
    }

    private struct PendingState {
        var lastStat: Stat?
        var stableCount: Int
        var firstSeenAt: ContinuousClock.Instant
    }

    private var pending: [String: PendingState] = [:]
    private let requiredStableChecks: Int
    private let checkInterval: Duration
    private let timeout: Duration
    private let fileManager = FileManager.default
    private let onSettled: @Sendable (String) -> Void
    private var tickTask: Task<Void, Never>?

    public init(
        requiredStableChecks: Int = 3,
        checkInterval: Duration = .milliseconds(400),
        timeout: Duration = .seconds(30),
        onSettled: @escaping @Sendable (String) -> Void
    ) {
        self.requiredStableChecks = requiredStableChecks
        self.checkInterval = checkInterval
        self.timeout = timeout
        self.onSettled = onSettled
    }

    /// Marks `path` as needing to settle before ingestion should touch it. Safe to call
    /// repeatedly for the same path (e.g. multiple FSEvents callbacks for one copy) —
    /// an already-pending path's stability count is not reset by a redundant mark.
    public func markDirty(_ path: String) {
        if pending[path] == nil {
            pending[path] = PendingState(lastStat: nil, stableCount: 0, firstSeenAt: .now)
        }
        ensureTicking()
    }

    private func ensureTicking() {
        guard tickTask == nil else { return }
        let interval = checkInterval
        tickTask = Task { [weak self] in
            while let self {
                try? await Task.sleep(for: interval)
                let hasMore = await self.tick()
                if !hasMore { break }
            }
        }
    }

    @discardableResult
    private func tick() -> Bool {
        for (path, state) in pending {
            if ContinuousClock.now - state.firstSeenAt > timeout {
                // Give up waiting for stability rather than losing the file forever —
                // a file that never stabilizes (rare) still deserves an ingest attempt.
                pending.removeValue(forKey: path)
                onSettled(path)
                continue
            }

            guard let attrs = try? fileManager.attributesOfItem(atPath: path) else {
                // Vanished mid-copy, or not readable yet — reset and keep waiting.
                pending[path] = PendingState(lastStat: nil, stableCount: 0, firstSeenAt: state.firstSeenAt)
                continue
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let stat = Stat(size: size, modificationDate: attrs[.modificationDate] as? Date)

            if stat == state.lastStat {
                let newCount = state.stableCount + 1
                if newCount >= requiredStableChecks {
                    pending.removeValue(forKey: path)
                    onSettled(path)
                } else {
                    pending[path] = PendingState(lastStat: stat, stableCount: newCount, firstSeenAt: state.firstSeenAt)
                }
            } else {
                pending[path] = PendingState(lastStat: stat, stableCount: 1, firstSeenAt: state.firstSeenAt)
            }
        }

        if pending.isEmpty {
            tickTask = nil
        }
        return !pending.isEmpty
    }
}
