import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct ProjectSuggestionServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase, hostPath: String) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: hostPath, label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    private func makeFile(_ db: SQLiteSpoolDatabase, rootId: Int64, path: String) async throws -> Int64 {
        let url = URL(fileURLWithPath: path)
        let file = try await db.writer.write { conn in
            try SpoolFile(
                watchedRootId: rootId, path: path, filename: url.lastPathComponent,
                ext: url.pathExtension, sizeBytes: 1
            ).inserted(conn)
        }
        return file.id!
    }

    private func projectMemberships(_ db: SQLiteSpoolDatabase) async throws -> [ProjectFile] {
        try await db.writer.read { conn in try ProjectFile.fetchAll(conn) }
    }

    private func projects(_ db: SQLiteSpoolDatabase) async throws -> [Project] {
        try await db.writer.read { conn in try Project.fetchAll(conn) }
    }

    @Test func loneFileInASubfolderGetsASuggestedProjectNamedAfterTheFolder() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Cool Kit/widget.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: fileId)

        let allProjects = try await projects(db)
        #expect(allProjects.count == 1)
        #expect(allProjects.first?.name == "Cool Kit")
        #expect(allProjects.first?.sourceFolderPath == "/tmp/Library/Cool Kit")

        let memberships = try await projectMemberships(db)
        #expect(memberships.count == 1)
        #expect(memberships.first?.status == .suggested)
    }

    @Test func fileDirectlyInTheWatchedRootGetsNoSuggestion() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Library/loose.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: fileId)

        #expect(try await projects(db).isEmpty)
        #expect(try await projectMemberships(db).isEmpty)
    }

    @Test func siblingFilesInTheSameFolderShareOneProject() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/a.stl")
        let b = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/b.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: a)
        try await service.suggestProject(forFileId: b)

        #expect(try await projects(db).count == 1, "both files sit in the same folder, so one shared project")
        #expect(try await projectMemberships(db).count == 2)
    }

    @Test func genericContainerFolderFallsBackToParentIdentity() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Galaxy Trash Can/files/lid.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: fileId)

        let allProjects = try await projects(db)
        #expect(allProjects.count == 1)
        #expect(allProjects.first?.name == "Galaxy Trash Can", "a bare 'files' folder isn't the project's real identity")
        #expect(allProjects.first?.sourceFolderPath == "/tmp/Library/Galaxy Trash Can")
    }

    @Test func twoUnrelatedKitsBothUsingTheGenericFilesConventionDoNotCollide() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Bookshelf Kit/files/a.stl")
        let b = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Benchy Variant/files/b.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: a)
        try await service.suggestProject(forFileId: b)

        let allProjects = try await projects(db)
        #expect(allProjects.count == 2, "matching by parent path, not the shared 'files' name, keeps these separate")
    }

    @Test func genericFolderDirectlyInRootFallsBackToKeepingItsOwnName() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        // "files" sits directly in the watched root — no more-meaningful parent exists.
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Library/files/a.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: fileId)

        let allProjects = try await projects(db)
        #expect(allProjects.count == 1)
        #expect(allProjects.first?.name == "files")
    }

    @Test func matchingSurvivesAProjectRenameBecauseItKeysOnFolderPath() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/a.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: a)

        // User renames the auto-created project (the pencil-edit UI).
        try await db.writer.write { conn in
            try conn.execute(sql: "UPDATE projects SET name = 'My Renamed Project' WHERE id = (SELECT id FROM projects LIMIT 1)")
        }

        let b = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/b.stl")
        try await service.suggestProject(forFileId: b)

        #expect(try await projects(db).count == 1, "a rename must not spawn a second project for the same folder")
    }

    @Test func rejectingASuggestionIsNotReintroducedByALaterRescan() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let a = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/a.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: a)

        try await db.writer.write { conn in
            try conn.execute(sql: "UPDATE project_files SET status = 'rejected'")
        }

        // Re-running (e.g. a rescan touching the same file) must not resurrect it.
        try await service.suggestProject(forFileId: a)

        let memberships = try await projectMemberships(db)
        #expect(memberships.count == 1)
        #expect(memberships.first?.status == .rejected)
    }

    @Test func soloFileMatchingItsFolderNameIsSkipped() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Widget Stand/Widget Stand.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: fileId)

        #expect(try await projects(db).isEmpty)
        #expect(try await projectMemberships(db).isEmpty)
    }

    @Test func soloFileSkipIgnoresCasePunctuationAndExtension() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Widget-Stand/widget_stand!.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: fileId)

        #expect(try await projects(db).isEmpty)
    }

    @Test func aSecondDifferentlyNamedFileSweepsInThePreviouslySkippedSoloFile() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let solo = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Widget Stand/Widget Stand.stl")
        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: solo)
        #expect(try await projects(db).isEmpty, "confirmed skipped while still alone")

        let extra = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Widget Stand/base.stl")
        try await service.suggestProject(forFileId: extra)

        let allProjects = try await projects(db)
        #expect(allProjects.count == 1)
        #expect(allProjects.first?.name == "Widget Stand")
        let memberships = try await projectMemberships(db)
        #expect(memberships.count == 2, "both files, including the originally-skipped one")
    }

    @Test func modelFilesAndPrintFilesSiblingFoldersShareOneProject() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let modelFile = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit-model_files/part.stl")
        let printFile = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit-print_files/part.gcode")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: modelFile)
        try await service.suggestProject(forFileId: printFile)

        let allProjects = try await projects(db)
        #expect(allProjects.count == 1, "the two halves of a kit split by file type must share one project")
        let memberships = try await projectMemberships(db)
        #expect(memberships.count == 2)
    }

    @Test func twoSiblingLeafProjectsGetWrappedUnderANewParentProject() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let europe = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/1_Europe/a.stl")
        let asia = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/2_Asia/b.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: europe)
        try await service.suggestProject(forFileId: asia)

        let allProjects = try await projects(db)
        #expect(allProjects.count == 3, "two leaf projects plus one new wrapper")
        let wrapper = try #require(allProjects.first(where: { $0.name == "Kit" }))
        let leaves = allProjects.filter { $0.id != wrapper.id }
        #expect(leaves.count == 2)
        #expect(leaves.allSatisfy { $0.parentProjectId == wrapper.id })
    }

    @Test func aSingleLeafProjectDoesNotGetWrapped() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/1_Europe/a.stl")

        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: fileId)

        let allProjects = try await projects(db)
        #expect(allProjects.count == 1, "not worth wrapping a single project")
        #expect(allProjects.first?.parentProjectId == nil)
    }

    @Test func aThirdSiblingJoinsTheAlreadyExistingWrapper() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/1_Europe/a.stl"))
        try await service.suggestProject(forFileId: try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/2_Asia/b.stl"))

        try await service.suggestProject(forFileId: try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/3_Africa/c.stl"))

        let allProjects = try await projects(db)
        #expect(allProjects.count == 4, "two original leaves + the wrapper + the new third leaf")
        let wrapper = try #require(allProjects.first(where: { $0.name == "Kit" }))
        let leaves = allProjects.filter { $0.id != wrapper.id }
        #expect(leaves.count == 3)
        #expect(leaves.allSatisfy { $0.parentProjectId == wrapper.id })
    }

    @Test func wrapperGroupingSkipsArchiveAncestorFolders() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")
        let service = ProjectSuggestionService(writer: db.writer)
        // "Archive" sits between the two leaf folders and their real common parent.
        try await service.suggestProject(forFileId: try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/Archive/1_Europe/a.stl"))
        try await service.suggestProject(forFileId: try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/Archive/2_Asia/b.stl"))

        let allProjects = try await projects(db)
        let wrapper = try #require(allProjects.first(where: { $0.name == "Kit" }))
        #expect(wrapper.sourceFolderPath == "/tmp/Library/Kit", "the wrapper must land on Kit, not the meaningless Archive folder")
    }

    @Test func manuallyCreatedProjectIsNeverAMatchCandidateEvenWithTheSameName() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db, hostPath: "/tmp/Library")

        // A manually-created project with no source_folder_path, coincidentally named
        // the same as a real folder.
        let manual = Project(name: "Kit", sourceFolderPath: nil)
        _ = try await db.writer.write { conn in try manual.inserted(conn) }

        let fileId = try await makeFile(db, rootId: rootId, path: "/tmp/Library/Kit/a.stl")
        let service = ProjectSuggestionService(writer: db.writer)
        try await service.suggestProject(forFileId: fileId)

        let allProjects = try await projects(db)
        #expect(allProjects.count == 2, "the manual project must not silently absorb this suggestion")
    }
}
