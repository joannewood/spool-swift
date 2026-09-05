import Foundation
import Testing
@testable import SpoolCore

/// Direct unit tests for `FolderRelocation`, mirroring the source app's
/// `test_ingest.py` relocate suite test-by-test — these scenarios are also exercised
/// indirectly through `BackfillService`/`RescanService`, but are worth pinning down in
/// isolation since the whole-folder-vs-single-file branch and its collision-naming
/// rules are the trickiest part of the `relocate_to_dropfolder` feature.
@Suite struct FolderRelocationTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FolderRelocationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(dir.path, &buffer) != nil else { return dir }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    @Test func rootLevelFileFlattensIntoDropfolder() throws {
        let downloadsDir = try makeTempDir()
        let dropDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: downloadsDir)
            try? FileManager.default.removeItem(at: dropDir)
        }
        let src = downloadsDir.appendingPathComponent("widget.stl")
        try "x".write(to: src, atomically: true, encoding: .utf8)

        let dest = try FolderRelocation.relocateFileOrFolder(sourceURL: src, rootURL: downloadsDir, dropFolderRootURL: dropDir)

        #expect(dest?.path == dropDir.appendingPathComponent("widget.stl").path)
        #expect(FileManager.default.fileExists(atPath: dest!.path))
        #expect(!FileManager.default.fileExists(atPath: src.path))
    }

    @Test func rootLevelCollisionGetsHashSuffix() throws {
        let downloadsDir = try makeTempDir()
        let dropDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: downloadsDir)
            try? FileManager.default.removeItem(at: dropDir)
        }
        try "already-here".write(to: dropDir.appendingPathComponent("widget.stl"), atomically: true, encoding: .utf8)
        let src = downloadsDir.appendingPathComponent("widget.stl")
        try "incoming-different-bytes".write(to: src, atomically: true, encoding: .utf8)

        let dest = try FolderRelocation.relocateFileOrFolder(sourceURL: src, rootURL: downloadsDir, dropFolderRootURL: dropDir)

        #expect(dest?.path != dropDir.appendingPathComponent("widget.stl").path)
        #expect(dest!.lastPathComponent.hasPrefix("widget ("))
        #expect(FileManager.default.fileExists(atPath: dest!.path))
        // the pre-existing file at the plain destination name is untouched
        let existing = try String(contentsOf: dropDir.appendingPathComponent("widget.stl"), encoding: .utf8)
        #expect(existing == "already-here")
    }

    @Test func leafFolderMovesWholeFolder() throws {
        let downloadsDir = try makeTempDir()
        let dropDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: downloadsDir)
            try? FileManager.default.removeItem(at: dropDir)
        }
        let kitDir = downloadsDir.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: kitDir, withIntermediateDirectories: true)
        let partA = kitDir.appendingPathComponent("part_a.stl")
        try "x".write(to: partA, atomically: true, encoding: .utf8)
        try "x".write(to: kitDir.appendingPathComponent("part_b.stl"), atomically: true, encoding: .utf8)
        try "x".write(to: kitDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let dest = try FolderRelocation.relocateFileOrFolder(sourceURL: partA, rootURL: downloadsDir, dropFolderRootURL: dropDir)

        #expect(dest?.path == dropDir.appendingPathComponent("Kit").appendingPathComponent("part_a.stl").path)
        #expect(!FileManager.default.fileExists(atPath: kitDir.path), "whole source folder moved, not copied")
        let movedDir = dropDir.appendingPathComponent("Kit")
        #expect(FileManager.default.fileExists(atPath: movedDir.appendingPathComponent("part_a.stl").path))
        #expect(FileManager.default.fileExists(atPath: movedDir.appendingPathComponent("part_b.stl").path))
        #expect(FileManager.default.fileExists(atPath: movedDir.appendingPathComponent("README.txt").path), "sidecar carried along")
    }

    @Test func leafFolderCollisionGetsNumericSuffix() throws {
        let downloadsDir = try makeTempDir()
        let dropDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: downloadsDir)
            try? FileManager.default.removeItem(at: dropDir)
        }
        let existingKit = dropDir.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: existingKit, withIntermediateDirectories: true)
        try "x".write(to: existingKit.appendingPathComponent("existing.stl"), atomically: true, encoding: .utf8)

        let kitDir = downloadsDir.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: kitDir, withIntermediateDirectories: true)
        let partA = kitDir.appendingPathComponent("part_a.stl")
        try "x".write(to: partA, atomically: true, encoding: .utf8)

        let dest = try FolderRelocation.relocateFileOrFolder(sourceURL: partA, rootURL: downloadsDir, dropFolderRootURL: dropDir)

        #expect(dest?.path == dropDir.appendingPathComponent("Kit (2)").appendingPathComponent("part_a.stl").path)
        // the pre-existing "Kit" folder at the destination is untouched, not merged into
        #expect(FileManager.default.fileExists(atPath: existingKit.appendingPathComponent("existing.stl").path))
        #expect(!FileManager.default.fileExists(atPath: existingKit.appendingPathComponent("part_a.stl").path))
    }

    /// A file whose containing folder has its *own* subdirectory (e.g. a `nested/`
    /// folder sitting next to `part_a.stl` inside `Kit/`) used to fall back to
    /// flattening just this one file, leaving `Kit/` — subdirectory and all — behind
    /// in Downloads. Confirmed live as a real problem, not just a cosmetic scope
    /// limit: this is exactly the shape of a real Printables/Thingiverse download
    /// (`<Kit>/files/*.stl` next to `<Kit>/images/*.jpg`), so the *whole* top-level
    /// `Kit` folder is now moved as one unit regardless of how deep `part_a.stl` sits
    /// inside it, carrying every subfolder and sidecar along for free.
    @Test func topLevelFolderMovesAsAWholeEvenWithNestedSubdirectories() throws {
        let downloadsDir = try makeTempDir()
        let dropDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: downloadsDir)
            try? FileManager.default.removeItem(at: dropDir)
        }
        let kitDir = downloadsDir.appendingPathComponent("Kit")
        let filesDir = kitDir.appendingPathComponent("files")
        let imagesDir = kitDir.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        let partA = filesDir.appendingPathComponent("part_a.stl")
        try "x".write(to: partA, atomically: true, encoding: .utf8)
        try "x".write(to: imagesDir.appendingPathComponent("preview.jpg"), atomically: true, encoding: .utf8)
        try "x".write(to: kitDir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        let dest = try FolderRelocation.relocateFileOrFolder(sourceURL: partA, rootURL: downloadsDir, dropFolderRootURL: dropDir)

        let expectedKitDir = dropDir.appendingPathComponent("Kit")
        #expect(dest?.path == expectedKitDir.appendingPathComponent("files").appendingPathComponent("part_a.stl").path)
        #expect(!FileManager.default.fileExists(atPath: kitDir.path), "whole top-level folder moved, not left behind")
        #expect(FileManager.default.fileExists(atPath: expectedKitDir.appendingPathComponent("files/part_a.stl").path))
        #expect(FileManager.default.fileExists(atPath: expectedKitDir.appendingPathComponent("images/preview.jpg").path), "sidecar images carried along")
        #expect(FileManager.default.fileExists(atPath: expectedKitDir.appendingPathComponent("README.txt").path), "sidecar readme carried along")
    }

    @Test func alreadyRelocatedByConcurrentHandlerReturnsNil() throws {
        let downloadsDir = try makeTempDir()
        let dropDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: downloadsDir)
            try? FileManager.default.removeItem(at: dropDir)
        }
        let kitDir = downloadsDir.appendingPathComponent("Kit")
        try FileManager.default.createDirectory(at: kitDir, withIntermediateDirectories: true)
        let partA = kitDir.appendingPathComponent("part_a.stl")
        try "x".write(to: partA, atomically: true, encoding: .utf8)

        // simulate a sibling file's event having already won the race and moved the
        // whole folder away before this call runs
        try FileManager.default.moveItem(at: kitDir, to: dropDir.appendingPathComponent("Kit"))

        let dest = try FolderRelocation.relocateFileOrFolder(sourceURL: partA, rootURL: downloadsDir, dropFolderRootURL: dropDir)
        #expect(dest == nil)
    }
}
