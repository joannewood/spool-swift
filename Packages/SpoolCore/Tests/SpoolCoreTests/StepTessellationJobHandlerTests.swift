import Foundation
import GRDB
import Testing
@testable import SpoolCore

/// Exercises the real `step-tessellate` helper (built standalone under
/// `Tools/StepConverter`, see M5) rather than mocking it — the whole point of building
/// it as an independent sub-project first was to validate it against real OCCT output
/// before any Swift interop, so these tests point straight at that binary and a real
/// STEP fixture rather than stubbing the conversion. Skips (not fails) if the binary
/// hasn't been built locally yet — it isn't produced by `swift build`, only by
/// `Tools/StepConverter/build.sh`, so a machine that hasn't run that script shouldn't
/// break the rest of the suite.
@Suite struct StepTessellationJobHandlerTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // StepTessellationJobHandlerTests.swift
            .deletingLastPathComponent() // SpoolCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // SpoolCore
            .deletingLastPathComponent() // Packages
    }

    private static var converterURL: URL { repoRoot.appendingPathComponent("Tools/StepConverter/step-tessellate") }
    private static var fixtureSTEPURL: URL { repoRoot.appendingPathComponent("Tools/StepConverter/box_with_hole.step") }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SpoolCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRoot(_ db: SQLiteSpoolDatabase) async throws -> WatchedRoot {
        let root = WatchedRoot(hostPath: "/tmp/whatever", label: "Test", kind: .dropFolder, bookmarkData: Data())
        return try await db.writer.write { conn in try root.inserted(conn) }
    }

    @Test func tessellatesRealStepFileEndToEnd() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.converterURL.path) else {
            print("skipping: step-tessellate not built locally (run Tools/StepConverter/build.sh)")
            return
        }
        guard FileManager.default.fileExists(atPath: Self.fixtureSTEPURL.path) else {
            print("skipping: no STEP fixture at \(Self.fixtureSTEPURL.path)")
            return
        }

        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let thumbsDir = tempDir.appendingPathComponent("Thumbnails")
        try FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)

        let stepURL = tempDir.appendingPathComponent("box_with_hole.step")
        try FileManager.default.copyItem(at: Self.fixtureSTEPURL, to: stepURL)

        let stub = SpoolFile(watchedRootId: root.id!, path: stepURL.path, filename: "box_with_hole.step", ext: "step", sizeBytes: 10)
        let inserted = try await db.writer.write { conn in try stub.inserted(conn) }

        let handler = StepTessellationJobHandler(writer: db.writer, thumbnailsDirectory: thumbsDir, converterURL: Self.converterURL)
        try await handler.handle(Job(fileId: inserted.id, jobType: .renderStep))

        let updated = try #require(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: inserted.id!) })
        #expect(updated.renderStatus == .done)
        #expect(updated.isManifold == true)
        #expect(updated.triCount == 276)
        #expect(updated.volumeMm3 != nil)
        let thumbPath = try #require(updated.thumbnailPath)
        #expect(FileManager.default.fileExists(atPath: thumbsDir.appendingPathComponent(thumbPath).path))
    }

    @Test func missingConverterFallsBackToUnsupported() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let root = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stub = SpoolFile(watchedRootId: root.id!, path: "/tmp/nonexistent.step", filename: "nonexistent.step", ext: "step", sizeBytes: 0)
        let inserted = try await db.writer.write { conn in try stub.inserted(conn) }

        let handler = StepTessellationJobHandler(writer: db.writer, thumbnailsDirectory: tempDir, converterURL: nil)
        try await handler.handle(Job(fileId: inserted.id, jobType: .renderStep))

        let updated = try #require(try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: inserted.id!) })
        #expect(updated.renderStatus == .unsupported)
    }
}
