import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct SidecarServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp", label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SidecarServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func stagesATextSidecarWithNoThumbnail() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let readmeURL = tempDir.appendingPathComponent("README.txt")
        try "hello".write(to: readmeURL, atomically: true, encoding: .utf8)

        let service = SidecarService(writer: db.writer, thumbnailsDirectory: nil)
        let sidecarId = try await service.stage(path: readmeURL.path, watchedRootId: rootId)

        #expect(sidecarId != nil)
        let stored = try await db.writer.read { conn in try SidecarFile.fetchOne(conn, id: sidecarId!) }
        #expect(stored?.filename == "README.txt")
        #expect(stored?.thumbnailPath == nil)
        #expect(stored?.status == .active)
    }

    @Test func stagingTheSamePathTwiceIsANoOp() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let readmeURL = tempDir.appendingPathComponent("README.txt")
        try "hello".write(to: readmeURL, atomically: true, encoding: .utf8)

        let service = SidecarService(writer: db.writer, thumbnailsDirectory: nil)
        let firstId = try await service.stage(path: readmeURL.path, watchedRootId: rootId)
        let secondId = try await service.stage(path: readmeURL.path, watchedRootId: rootId)

        #expect(firstId != nil)
        #expect(secondId == nil, "already-known path must be a no-op")
        let count = try await db.writer.read { conn in try SidecarFile.fetchCount(conn) }
        #expect(count == 1)
    }

    @Test func imageSidecarGetsAThumbnailCopy() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let thumbsDir = tempDir.appendingPathComponent("Thumbnails")
        let imageURL = tempDir.appendingPathComponent("preview.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)

        let service = SidecarService(writer: db.writer, thumbnailsDirectory: thumbsDir)
        let sidecarId = try await service.stage(path: imageURL.path, watchedRootId: rootId)

        let stored = try await db.writer.read { conn in try SidecarFile.fetchOne(conn, id: sidecarId!) }
        let thumbnailPath = try #require(stored?.thumbnailPath)
        #expect(thumbnailPath == "sidecar-\(sidecarId!).png")
        #expect(FileManager.default.fileExists(atPath: thumbsDir.appendingPathComponent(thumbnailPath).path))
    }

    @Test func sidecarsForProjectMatchesConfirmedMemberFolders() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let kitDir = tempDir.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: kitDir, withIntermediateDirectories: true)
        let otherDir = tempDir.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        let readmeURL = kitDir.appendingPathComponent("README.txt")
        try "hi".write(to: readmeURL, atomically: true, encoding: .utf8)
        let unrelatedReadmeURL = otherDir.appendingPathComponent("README.txt")
        try "hi".write(to: unrelatedReadmeURL, atomically: true, encoding: .utf8)

        let sidecarService = SidecarService(writer: db.writer, thumbnailsDirectory: nil)
        try await sidecarService.stage(path: readmeURL.path, watchedRootId: rootId)
        try await sidecarService.stage(path: unrelatedReadmeURL.path, watchedRootId: rootId)

        let modelFile = try await db.writer.write { conn in
            try SpoolFile(
                watchedRootId: rootId, path: kitDir.appendingPathComponent("part.stl").path,
                filename: "part.stl", ext: "stl", sizeBytes: 1
            ).inserted(conn)
        }
        let project = try await db.writer.write { conn in try Project(name: "Kit").inserted(conn) }
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'confirmed')",
                arguments: [project.id!, modelFile.id!]
            )
        }

        let sidecars = try await sidecarService.sidecars(inProjectId: project.id!)
        #expect(sidecars.map(\.filename) == ["README.txt"])
        #expect(sidecars.first?.path == readmeURL.path, "only the sidecar in the confirmed member's own folder")
    }
}
