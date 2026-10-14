import Foundation
import GRDB
import SpoolCore

@MainActor
final class FileDetailViewModel: ObservableObject {
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var projects: [Project] = []
    @Published private(set) var printMetadata: PrintMetadata?
    @Published private(set) var galleryImages: [FileGalleryImage] = []
    @Published var lastError: String?

    /// Where this file's copy actually lives on disk, if the export placed one we can
    /// find — resolved against every project this file belongs to (in this curated
    /// export, that's almost always exactly one), since `IPadExportService` organizes
    /// copies as `Files/<sanitizedFolderName(project.name)>/<filename>`.
    @Published private(set) var localFileURL: URL?

    /// True once we know the file genuinely belongs to a shared project (so a local
    /// copy should eventually exist) but haven't found it on disk yet — distinct from
    /// "this file was never exported at all," which `localFileURL` staying nil after
    /// `projects` is non-empty and the retry loop in the view gives up would indicate.
    var isWaitingForFileDownload: Bool { localFileURL == nil && !projects.isEmpty }

    func load(file: SpoolFile, database: SQLiteSpoolDatabase?, folderURL: URL?) async {
        guard let database, let fileId = file.id else { return }
        do {
            tags = try await TagService(writer: database.writer).tags(forFileId: fileId)
            let memberships = try await ProjectService(writer: database.writer).projectMemberships(forFileId: fileId)
            let allProjects = try await ProjectService(writer: database.writer).allProjects()
            let projectIds = Set(memberships.map(\.projectId))
            projects = allProjects.filter { projectIds.contains($0.id ?? -1) }
            printMetadata = try await database.writer.read { conn in try PrintMetadata.fetchOne(conn, key: fileId) }
            galleryImages = try await FileGalleryService(writer: database.writer, thumbnailsDirectory: nil).images(forFileId: fileId)

            if let folderURL {
                localFileURL = projects
                    .map { folderURL.appendingPathComponent("Files/\(IPadExportService.sanitizedFolderName($0.name))/\(file.filename)") }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            }
        } catch {
            lastError = "\(error)"
        }
    }
}
