import Foundation
import Testing
@testable import SpoolFS

@Suite struct SecurityScopedBookmarkTests {
    @Test func bookmarkRoundTripsToTheSameFolder() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpoolFSTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bookmarkData = try SecurityScopedBookmark.create(for: tempDir)
        let (resolvedURL, isStale) = try SecurityScopedBookmark.resolve(bookmarkData)

        #expect(resolvedURL.standardizedFileURL.path == tempDir.standardizedFileURL.path)
        #expect(isStale == false)
    }

    @Test func securityScopedAccessGrantsReadableURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpoolFSTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let markerFile = tempDir.appendingPathComponent("marker.txt")
        try "hello".write(to: markerFile, atomically: true, encoding: .utf8)

        let bookmarkData = try SecurityScopedBookmark.create(for: tempDir)
        let access = try SecurityScopedAccess.resolve(bookmarkData: bookmarkData)
        defer { access.stop() }

        #expect(FileManager.default.fileExists(atPath: access.url.appendingPathComponent("marker.txt").path))
    }
}
