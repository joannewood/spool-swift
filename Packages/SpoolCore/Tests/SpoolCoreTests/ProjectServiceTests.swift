import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct ProjectServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase, kind: RootKind = .library) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp/\(UUID().uuidString)", label: "x", kind: kind, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    private func makeFile(_ db: SQLiteSpoolDatabase, rootId: Int64, path: String = "/tmp/a.stl") async throws -> Int64 {
        let file = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: rootId, path: path, filename: (path as NSString).lastPathComponent, ext: "stl", sizeBytes: 1)
                .inserted(conn)
        }
        return file.id!
    }

    @Test func createRenameAndReparent() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)

        let parent = try await service.createProject(name: "Parent")
        let child = try await service.createProject(name: "Child", parentProjectId: parent.id)

        try await service.rename(projectId: child.id!, to: "Renamed Child")
        let allProjects = try await service.allProjects()
        #expect(allProjects.first(where: { $0.id == child.id })?.name == "Renamed Child")

        let roots = try await service.childProjects(ofParentId: nil)
        #expect(roots.map(\.name) == ["Parent"])
        let children = try await service.childProjects(ofParentId: parent.id)
        #expect(children.map(\.name) == ["Renamed Child"])
    }

    @Test func newProjectsDefaultToBlue() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "Kit")
        #expect(project.color == .blue)
    }

    @Test func coloredProjectsSortBeforeBlueOnesRegardlessOfName() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        _ = try await service.createProject(name: "Alpha") // blue, sorts first alphabetically otherwise
        let zebra = try await service.createProject(name: "Zebra")
        try await service.setColor(projectId: zebra.id!, to: .red)

        let projects = try await service.allProjects()

        #expect(projects.map(\.name) == ["Zebra", "Alpha"], "the colored project must lead even though 'Alpha' sorts first alphabetically")
        #expect(projects.first?.color == .red)
    }

    @Test func projectSummariesRespectTheSameColorFirstOrdering() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        _ = try await service.createProject(name: "Alpha")
        let zebra = try await service.createProject(name: "Zebra")
        try await service.setColor(projectId: zebra.id!, to: .green)

        let summaries = try await service.projectSummaries()

        #expect(summaries.map(\.project.name) == ["Zebra", "Alpha"])
        #expect(summaries.first?.project.color == .green)
    }

    @Test func reparentToSelfIsIgnored() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "Solo")

        try await service.reparent(projectId: project.id!, toParentId: project.id!)

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: project.id!) }
        #expect(refetched?.parentProjectId == nil, "a project must never become its own parent")
    }

    @Test func addAndRemoveFileMembershipIsAlwaysConfirmed() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId)
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "Kit")

        try await service.addFile(fileId: fileId, toProjectId: project.id!)
        let memberships = try await service.projectMemberships(forFileId: fileId)
        #expect(memberships.count == 1)
        #expect(memberships.first?.status == .confirmed, "a manual add is always confirmed, unlike heuristic suggestions")

        let files = try await service.confirmedFiles(inProjectId: project.id!)
        #expect(files.map(\.id) == [fileId])

        try await service.removeFile(fileId: fileId, fromProjectId: project.id!)
        #expect(try await service.projectMemberships(forFileId: fileId).isEmpty)
    }

    @Test func removeFileDeletesNowEmptyAutoCreatedProject() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId)
        let service = ProjectService(writer: db.writer)
        let autoProject = try await db.writer.write { conn in
            try Project(name: "Kit", sourceFolderPath: "/tmp/Kit").inserted(conn)
        }
        try await service.addFile(fileId: fileId, toProjectId: autoProject.id!)

        try await service.removeFile(fileId: fileId, fromProjectId: autoProject.id!)

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: autoProject.id!) }
        #expect(refetched == nil, "an auto-created project left with zero files is dead weight")
    }

    @Test func removeFileKeepsEmptyManuallyCreatedProject() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId)
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "Kit") // no sourceFolderPath — manually created
        try await service.addFile(fileId: fileId, toProjectId: project.id!)

        try await service.removeFile(fileId: fileId, fromProjectId: project.id!)

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: project.id!) }
        #expect(refetched != nil, "the user made this project on purpose — never auto-deleted, even empty")
    }

    @Test func removeFileKeepsAutoCreatedProjectWithRemainingMembers() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileA = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let fileB = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let service = ProjectService(writer: db.writer)
        let autoProject = try await db.writer.write { conn in
            try Project(name: "Kit", sourceFolderPath: "/tmp/Kit").inserted(conn)
        }
        try await service.addFiles(fileIds: [fileA, fileB], toProjectId: autoProject.id!)

        try await service.removeFile(fileId: fileA, fromProjectId: autoProject.id!)

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: autoProject.id!) }
        #expect(refetched != nil, "still has fileB — must not be deleted")
    }

    @Test func addFilesBulkAddsEveryGivenFile() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileA = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        let fileB = try await makeFile(db, rootId: rootId, path: "/tmp/b.stl")
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "Kit")

        try await service.addFiles(fileIds: [fileA, fileB], toProjectId: project.id!)

        let files = try await service.confirmedFiles(inProjectId: project.id!)
        #expect(Set(files.map(\.id)) == [fileA, fileB])
    }

    @Test func addingAFileConfirmsAnExistingSuggestedMembershipRatherThanDuplicating() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId)
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "Kit", parentProjectId: nil)

        // Simulate an existing suggested membership (as ProjectSuggestionService would create).
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'suggested')",
                arguments: [project.id!, fileId]
            )
        }

        try await service.addFile(fileId: fileId, toProjectId: project.id!)

        let memberships = try await service.projectMemberships(forFileId: fileId)
        #expect(memberships.count == 1)
        #expect(memberships.first?.status == .confirmed)
    }

    @Test func confirmedFilesExcludesSuggestedAndInactiveFiles() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let confirmedFileId = try await makeFile(db, rootId: rootId, path: "/tmp/confirmed.stl")
        let suggestedFileId = try await makeFile(db, rootId: rootId, path: "/tmp/suggested.stl")
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "Kit")

        try await service.addFile(fileId: confirmedFileId, toProjectId: project.id!)
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, 'suggested')",
                arguments: [project.id!, suggestedFileId]
            )
        }

        let files = try await service.confirmedFiles(inProjectId: project.id!)
        #expect(files.map(\.id) == [confirmedFileId])
    }

    @Test func projectsNeedingNameCleanupOnlySurfacesActualChanges() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        _ = try await service.createProject(name: "towel-hanger-model_files")
        _ = try await service.createProject(name: "Already Clean")

        let suggestions = try await service.projectsNeedingNameCleanup()
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.project.name == "towel-hanger-model_files")
        #expect(suggestions.first?.suggestedName == "Towel Hanger")
    }

    @Test func renameProjectsBulkAppliesEditedNames() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "towel-hanger-model_files")
        let untouched = try await service.createProject(name: "widget-model_files")

        // Simulate a user hand-editing the suggested name before applying, and only
        // checking one of the two available rows.
        try await service.renameProjectsBulk([(projectId: project.id!, newName: "My Custom Towel Hanger")])

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: project.id!) }
        #expect(refetched?.name == "My Custom Towel Hanger")

        let refetchedUntouched = try await db.writer.read { conn in try Project.fetchOne(conn, id: untouched.id!) }
        #expect(refetchedUntouched?.name == "widget-model_files", "an unchecked row must be left completely alone")
    }

    @Test func renameProjectsBulkSkipsBlankNamesWithoutFailingTheBatch() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        let blank = try await service.createProject(name: "blank-target-model_files")
        let real = try await service.createProject(name: "real-target-model_files")

        try await service.renameProjectsBulk([
            (projectId: blank.id!, newName: "   "),
            (projectId: real.id!, newName: "Real Target"),
        ])

        let refetchedBlank = try await db.writer.read { conn in try Project.fetchOne(conn, id: blank.id!) }
        #expect(refetchedBlank?.name == "blank-target-model_files")
        let refetchedReal = try await db.writer.read { conn in try Project.fetchOne(conn, id: real.id!) }
        #expect(refetchedReal?.name == "Real Target")
    }

    @Test func renameProjectsBulkDisambiguatesEditedNamesThatCollide() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        _ = try await service.createProject(name: "Existing Name")
        let project = try await service.createProject(name: "raw-folder-name")

        try await service.renameProjectsBulk([(projectId: project.id!, newName: "Existing Name")])

        let refetched = try await db.writer.read { conn in try Project.fetchOne(conn, id: project.id!) }
        #expect(refetched?.name != "Existing Name", "must not create a duplicate name")
        #expect(refetched?.name.contains("Existing Name") == true)
    }

    @Test func renameAllNeedingCleanupDisambiguatesCollidingSuggestions() async throws {
        // Both of these clean up to the exact same string ("Widget") — the classic
        // "-model_files"/"-print_files" sibling-folder collision this guards against.
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        _ = try await service.createProject(name: "widget-model_files")
        _ = try await service.createProject(name: "widget-print_files")

        let renamedCount = try await service.renameAllNeedingCleanup()
        #expect(renamedCount == 2)

        let names = try await service.allProjects().map(\.name)
        #expect(Set(names).count == 2, "colliding suggestions must disambiguate rather than collapse to duplicate names")
        #expect(names.contains("Widget"))
    }

    @Test func renameAllNeedingCleanupIsIdempotent() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        _ = try await service.createProject(name: "towel-hanger-model_files")

        #expect(try await service.renameAllNeedingCleanup() == 1)
        #expect(try await service.renameAllNeedingCleanup() == 0, "a second pass over already-clean names must be a no-op")
    }

    @Test func mergeProjectsMovesFilesReparentsChildrenAndDeletesSource() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileInSource = try await makeFile(db, rootId: rootId, path: "/tmp/source-file.stl")
        let fileInBoth = try await makeFile(db, rootId: rootId, path: "/tmp/both-file.stl")
        let service = ProjectService(writer: db.writer)

        let source = try await service.createProject(name: "Source")
        let target = try await service.createProject(name: "Target")
        let sourceChild = try await service.createProject(name: "Source Child", parentProjectId: source.id)

        try await service.addFile(fileId: fileInSource, toProjectId: source.id!)
        try await service.addFile(fileId: fileInBoth, toProjectId: source.id!)
        try await service.addFile(fileId: fileInBoth, toProjectId: target.id!)

        let merged = try await service.mergeProjects(sourceId: source.id!, intoTargetId: target.id!)
        #expect(merged == true)

        let targetFiles = try await service.confirmedFiles(inProjectId: target.id!)
        #expect(Set(targetFiles.map(\.id)) == [fileInSource, fileInBoth])

        let refetchedChild = try await db.writer.read { conn in try Project.fetchOne(conn, id: sourceChild.id!) }
        #expect(refetchedChild?.parentProjectId == target.id, "source's children must be re-parented under target")

        let refetchedSource = try await db.writer.read { conn in try Project.fetchOne(conn, id: source.id!) }
        #expect(refetchedSource == nil, "source must be deleted after merging")
    }

    @Test func mergeProjectsSelfMergeIsANoOp() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "Solo")

        let merged = try await service.mergeProjects(sourceId: project.id!, intoTargetId: project.id!)
        #expect(merged == false)

        let stillExists = try await db.writer.read { conn in try Project.fetchOne(conn, id: project.id!) }
        #expect(stillExists != nil)
    }

    @Test func projectSummariesCountFilesAndSubprojectsRecursively() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId)
        let service = ProjectService(writer: db.writer)

        let umbrella = try await service.createProject(name: "Umbrella")
        let child = try await service.createProject(name: "Child", parentProjectId: umbrella.id)
        try await service.addFile(fileId: fileId, toProjectId: child.id!)

        let summaries = try await service.projectSummaries()
        let umbrellaSummary = try #require(summaries.first(where: { $0.project.id == umbrella.id }))
        #expect(umbrellaSummary.fileCount == 1, "an umbrella project's file count includes its descendants' files")
        #expect(umbrellaSummary.subprojectCount == 1)

        let childSummary = try #require(summaries.first(where: { $0.project.id == child.id }))
        #expect(childSummary.fileCount == 1)
        #expect(childSummary.subprojectCount == 0)
    }

    @Test func projectCardVisualsCollectsThumbnailsAndMergedExtensions() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let service = ProjectService(writer: db.writer)
        let project = try await service.createProject(name: "Kit")

        let stlFileId = try await makeFile(db, rootId: rootId, path: "/tmp/a.stl")
        try await db.writer.write { conn in
            try conn.execute(sql: "UPDATE files SET thumbnail_path = ? WHERE id = ?", arguments: ["a.png", stlFileId])
        }
        let stepFile = try await db.writer.write { conn in
            try SpoolFile(watchedRootId: rootId, path: "/tmp/b.step", filename: "b.step", ext: "step", sizeBytes: 1).inserted(conn)
        }
        try await service.addFile(fileId: stlFileId, toProjectId: project.id!)
        try await service.addFile(fileId: stepFile.id!, toProjectId: project.id!)

        let visuals = try await service.projectCardVisuals(forProjectIds: [project.id!])
        let visual = try #require(visuals[project.id!])
        #expect(visual.thumbnailPaths == ["a.png"])
        #expect(visual.extensions == ["STEP", "STL"], "the .step file's extension merges to STEP, alongside the .stl file's own")
    }
}
