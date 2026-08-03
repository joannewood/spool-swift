import Foundation
import Testing
@testable import SpoolFS

@Suite struct SettlementTrackerTests {
    private func makeTempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolFSTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("growing.stl")
    }

    @Test func settlesOnlyAfterSizeStopsChanging() async throws {
        let fileURL = try makeTempFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try "a".write(to: fileURL, atomically: true, encoding: .utf8)

        let settledPaths = SettledPathsBox()
        let tracker = SettlementTracker(
            requiredStableChecks: 3,
            checkInterval: .milliseconds(50),
            timeout: .seconds(5)
        ) { path in
            Task { await settledPaths.add(path) }
        }

        await tracker.markDirty(fileURL.path)

        // Simulate a file still being written: grow it a couple of times while the
        // tracker is polling, then stop — settlement should only fire after growth stops.
        try await Task.sleep(for: .milliseconds(60))
        try "ab".write(to: fileURL, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(60))
        try "abc".write(to: fileURL, atomically: true, encoding: .utf8)

        // Give it time to observe 3 consecutive stable reads of the final size.
        try await Task.sleep(for: .milliseconds(400))

        let paths = await settledPaths.all
        #expect(paths.contains(fileURL.path))
    }

    @Test func giveUpAfterTimeoutStillReportsSettled() async throws {
        // A path that never stabilizes (kept "vanishing" from the filesystem's
        // perspective by pointing at a nonexistent file) should still eventually be
        // reported once the timeout elapses, rather than being lost forever.
        let path = "/tmp/does-not-exist-\(UUID().uuidString).stl"
        let settledPaths = SettledPathsBox()
        let tracker = SettlementTracker(
            requiredStableChecks: 3,
            checkInterval: .milliseconds(20),
            timeout: .milliseconds(100)
        ) { path in
            Task { await settledPaths.add(path) }
        }

        await tracker.markDirty(path)
        try await Task.sleep(for: .milliseconds(300))

        let paths = await settledPaths.all
        #expect(paths.contains(path))
    }
}

private actor SettledPathsBox {
    private(set) var all: Set<String> = []
    func add(_ path: String) { all.insert(path) }
}
