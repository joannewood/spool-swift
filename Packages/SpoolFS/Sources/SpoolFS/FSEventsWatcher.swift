import CoreServices
import Foundation

/// Thin wrapper over the FSEvents API, replacing the source app's `watchdog`-based
/// Python watcher and its 10s `watched_roots` poll. `kFSEventStreamCreateFlagFileEvents`
/// gives per-file granularity (not just "something in this directory changed"), which
/// is what lets a dirty *path* (not a whole subtree) be handed to ingestion.
///
/// Deliberately reports raw events only — it does not try to interpret renames/moves
/// itself. Every callback should route into the same walk-and-diff backfill/rescan
/// logic already used at startup (see the project plan): that logic already detects
/// moves by content-hash reunification, which is the one reliable mechanism (bind-mount
/// fs events were proven unreliable for this in the source app; a native FSEvents
/// stream is more reliable but still not worth a second, parallel rename code path).
public final class FSEventsWatcher: @unchecked Sendable {
    public struct Event: Sendable {
        public let path: String
        public let flags: FSEventStreamEventFlags

        public var isDirectory: Bool { flags & UInt32(kFSEventStreamEventFlagItemIsDir) != 0 }
        public var isRemoved: Bool { flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 }
        public var isRenamed: Bool { flags & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 }
    }

    private let watchedPaths: [String]
    private let latency: TimeInterval
    private var streamRef: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.spool.fsevents")
    private let continuation: AsyncStream<Event>.Continuation
    public let events: AsyncStream<Event>

    public init(paths: [String], latency: TimeInterval = 0.5) {
        self.watchedPaths = paths
        self.latency = latency
        var continuation: AsyncStream<Event>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    public func start() {
        guard streamRef == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            fsEventsCallback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else { return }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
        continuation.finish()
    }

    fileprivate func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
        for (path, flag) in zip(paths, flags) {
            continuation.yield(Event(path: path, flags: flag))
        }
    }

    deinit {
        stop()
    }
}

private func fsEventsCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallbackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let clientCallbackInfo else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(clientCallbackInfo).takeUnretainedValue()
    guard let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else { return }
    let flagsBuffer = UnsafeBufferPointer(start: eventFlags, count: numEvents)
    watcher.handleEvents(paths: cfPaths, flags: Array(flagsBuffer))
}
