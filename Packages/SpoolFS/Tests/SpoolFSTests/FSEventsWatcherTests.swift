import Foundation
import Testing
@testable import SpoolFS

private actor EventCollector {
    private(set) var paths: [String] = []

    func collect(from stream: AsyncStream<FSEventsWatcher.Event>) {
        Task {
            for await event in stream {
                paths.append(event.path)
            }
        }
    }
}

@Suite struct FSEventsWatcherTests {
    @Test func detectsANewFileCreatedInAWatchedDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolFSTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = FSEventsWatcher(paths: [dir.path], latency: 0.1)
        let collector = EventCollector()
        await collector.collect(from: watcher.events)
        watcher.start()
        // FSEvents needs a moment to register the stream with the kernel before events
        // that happen after `start()` are reliably captured.
        try await Task.sleep(for: .milliseconds(300))

        let newFile = dir.appendingPathComponent("new-part.stl")
        try "hello".write(to: newFile, atomically: true, encoding: .utf8)

        let deadline = ContinuousClock.now + .seconds(5)
        var sawPath = false
        while ContinuousClock.now < deadline {
            let paths = await collector.paths
            // Match on the last path component, not a full prefix: FSEvents reports
            // paths through their real (symlink-resolved) form, e.g. `/private/var/...`
            // even when this process's own `dir.path` is the `/var/...` alias.
            if paths.contains(where: { $0.hasSuffix("new-part.stl") }) {
                sawPath = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        watcher.stop()

        #expect(sawPath, "expected an FSEvents callback mentioning the newly created file")
    }
}
