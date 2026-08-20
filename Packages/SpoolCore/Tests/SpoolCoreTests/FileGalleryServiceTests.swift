import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct FileGalleryServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp", label: "x", kind: .dropFolder, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FileGalleryServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(_ db: SQLiteSpoolDatabase, rootId: Int64, path: String) async throws -> Int64 {
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: rootId, path: path, filename: (path as NSString).lastPathComponent, ext: "stl", sizeBytes: 1)
                .inserted(conn)
        }
        return file.id!
    }

    private func fetchFile(_ db: SQLiteSpoolDatabase, id: Int64) async throws -> SpoolFile? {
        try await db.writer.read { conn in try SpoolFile.fetchOne(conn, id: id) }
    }

    @Test func matchDesignerPhotoFindsAndActivatesAnExactBaseNameMatch() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let modelURL = tempDir.appendingPathComponent("Widget.stl")
        try "x".write(to: modelURL, atomically: true, encoding: .utf8)
        let photoURL = tempDir.appendingPathComponent("Widget.jpg")
        try Data([0xFF, 0xD8]).write(to: photoURL)
        let fileId = try await makeFile(db, rootId: rootId, path: modelURL.path)

        let thumbsDir = tempDir.appendingPathComponent("Thumbnails")
        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: thumbsDir)
        try await service.matchDesignerPhoto(forFileId: fileId, filePath: modelURL.path)

        let images = try await service.images(forFileId: fileId)
        #expect(images.count == 1)
        #expect(images.first?.kind == .designerPhoto)
        #expect(images.first?.label == "Widget.jpg")
        let file = try await fetchFile(db, id: fileId)
        #expect(file?.activeGalleryImageId == images.first?.id, "auto-selected, matching the mockup's 'shown first' behavior")
        #expect(file?.thumbnailPath == images.first?.thumbnailPath)
    }

    @Test func matchDesignerPhotoDoesNothingWithNoMatchingImage() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let modelURL = tempDir.appendingPathComponent("Widget.stl")
        try "x".write(to: modelURL, atomically: true, encoding: .utf8)
        let fileId = try await makeFile(db, rootId: rootId, path: modelURL.path)

        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: tempDir.appendingPathComponent("Thumbnails"))
        try await service.matchDesignerPhoto(forFileId: fileId, filePath: modelURL.path)

        let images = try await service.images(forFileId: fileId)
        #expect(images.isEmpty)
    }

    @Test func matchDesignerPhotoIsIdempotent() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let modelURL = tempDir.appendingPathComponent("Widget.stl")
        try "x".write(to: modelURL, atomically: true, encoding: .utf8)
        try Data([0xFF, 0xD8]).write(to: tempDir.appendingPathComponent("Widget.jpg"))
        let fileId = try await makeFile(db, rootId: rootId, path: modelURL.path)

        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: tempDir.appendingPathComponent("Thumbnails"))
        try await service.matchDesignerPhoto(forFileId: fileId, filePath: modelURL.path)
        try await service.matchDesignerPhoto(forFileId: fileId, filePath: modelURL.path)

        let images = try await service.images(forFileId: fileId)
        #expect(images.count == 1, "a rescan/re-ingest of the same file must not duplicate the match")
    }

    @Test func recordRenderedThumbnailActivatesOnlyWhenNothingElseIsActive() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Widget.stl")
        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: nil)

        try await service.recordRenderedThumbnail(fileId: fileId, thumbnailPath: "123.png")

        let images = try await service.images(forFileId: fileId)
        #expect(images.count == 1)
        #expect(images.first?.kind == .rendered)
        let file = try await fetchFile(db, id: fileId)
        #expect(file?.thumbnailPath == "123.png")
        #expect(file?.activeGalleryImageId == images.first?.id)
    }

    @Test func recordRenderedThumbnailNeverStealsActivationFromAnAlreadyChosenPhoto() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let photoURL = tempDir.appendingPathComponent("mine.jpg")
        try Data([0xFF, 0xD8]).write(to: photoURL)
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Widget.stl")
        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: tempDir.appendingPathComponent("Thumbnails"))
        let uploaded = try await service.upload(fileId: fileId, sourceURL: photoURL)

        try await service.recordRenderedThumbnail(fileId: fileId, thumbnailPath: "123.png")

        let file = try await fetchFile(db, id: fileId)
        #expect(file?.activeGalleryImageId == uploaded.id, "a re-render must not steal activation away from the user's photo")
        #expect(file?.thumbnailPath == uploaded.thumbnailPath)
        let images = try await service.images(forFileId: fileId)
        #expect(images.count == 2, "the rendered slide is still recorded, just not activated")
    }

    @Test func uploadAddsAndActivatesImmediately() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let photoURL = tempDir.appendingPathComponent("mine.jpg")
        try Data([0xFF, 0xD8]).write(to: photoURL)
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Widget.stl")
        let thumbsDir = tempDir.appendingPathComponent("Thumbnails")
        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: thumbsDir)
        // Already has an active rendered thumbnail — upload must still take over.
        try await service.recordRenderedThumbnail(fileId: fileId, thumbnailPath: "123.png")

        let uploaded = try await service.upload(fileId: fileId, sourceURL: photoURL)

        #expect(uploaded.kind == .uploaded)
        #expect(FileManager.default.fileExists(atPath: thumbsDir.appendingPathComponent(uploaded.thumbnailPath).path))
        let file = try await fetchFile(db, id: fileId)
        #expect(file?.activeGalleryImageId == uploaded.id)
        #expect(file?.thumbnailPath == uploaded.thumbnailPath)
    }

    @Test func setActiveSwitchesTheActiveSlide() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Widget.stl")
        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: nil)
        try await service.recordRenderedThumbnail(fileId: fileId, thumbnailPath: "123.png")
        let images = try await service.images(forFileId: fileId)
        let renderedId = try #require(images.first?.id)

        // Force something else active first (simulating a photo), then switch back.
        try await db.writer.write { conn in
            try conn.execute(sql: "UPDATE files SET active_gallery_image_id = NULL, thumbnail_path = NULL WHERE id = ?", arguments: [fileId])
        }
        try await service.setActive(fileId: fileId, imageId: renderedId)

        let file = try await fetchFile(db, id: fileId)
        #expect(file?.activeGalleryImageId == renderedId)
        #expect(file?.thumbnailPath == "123.png")
    }

    @Test func deleteRejectsARenderedSlide() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Widget.stl")
        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: nil)
        try await service.recordRenderedThumbnail(fileId: fileId, thumbnailPath: "123.png")
        let renderedId = try #require(try await service.images(forFileId: fileId).first?.id)

        await #expect(throws: FileGalleryService.GalleryError.cannotDeleteRenderedThumbnail) {
            try await service.delete(imageId: renderedId, fileId: fileId)
        }
    }

    @Test func deletingTheActivePhotoFallsBackToTheRenderedThumbnail() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let photoURL = tempDir.appendingPathComponent("mine.jpg")
        try Data([0xFF, 0xD8]).write(to: photoURL)
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Widget.stl")
        let thumbsDir = tempDir.appendingPathComponent("Thumbnails")
        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: thumbsDir)
        try await service.recordRenderedThumbnail(fileId: fileId, thumbnailPath: "123.png")
        let uploaded = try await service.upload(fileId: fileId, sourceURL: photoURL)

        try await service.delete(imageId: uploaded.id!, fileId: fileId)

        let file = try await fetchFile(db, id: fileId)
        #expect(file?.thumbnailPath == "123.png", "must fall back to the rendered thumbnail, not be left blank")
        #expect(!FileManager.default.fileExists(atPath: thumbsDir.appendingPathComponent(uploaded.thumbnailPath).path))
        let images = try await service.images(forFileId: fileId)
        #expect(images.count == 1)
        #expect(images.first?.kind == .rendered)
    }

    @Test func imagesOrdersPhotosBeforeTheRenderedSlide() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let photoURL = tempDir.appendingPathComponent("mine.jpg")
        try Data([0xFF, 0xD8]).write(to: photoURL)
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Widget.stl")
        let service = FileGalleryService(writer: db.writer, thumbnailsDirectory: tempDir.appendingPathComponent("Thumbnails"))
        // Rendered first, chronologically, but must still sort last.
        try await service.recordRenderedThumbnail(fileId: fileId, thumbnailPath: "123.png")
        try await service.upload(fileId: fileId, sourceURL: photoURL)

        let images = try await service.images(forFileId: fileId)
        #expect(images.map(\.kind) == [.uploaded, .rendered])
    }
}
