import Foundation
import GRDB
import Testing
@testable import SpoolCore

@Suite struct SearchServiceTests {
    private func makeRoot(_ db: SQLiteSpoolDatabase) async throws -> Int64 {
        let root = try await db.writer.write { conn in
            try WatchedRoot(hostPath: "/tmp", label: "x", kind: .library, bookmarkData: Data()).inserted(conn)
        }
        return root.id!
    }

    @discardableResult
    private func makeFile(
        _ db: SQLiteSpoolDatabase, rootId: Int64, filename: String,
        firstSeenAt: Date = Date(), displayName: String? = nil
    ) async throws -> Int64 {
        let file = try await db.writer.write { conn in
            try SpoolFile(
                watchedRootId: rootId, path: "/tmp/\(filename)", filename: filename,
                ext: (filename as NSString).pathExtension, sizeBytes: 1,
                firstSeenAt: firstSeenAt, lastSeenAt: firstSeenAt, displayName: displayName
            ).inserted(conn)
        }
        return file.id!
    }

    @Test func normalizedSearchTreatsHyphenUnderscoreSpaceAsEquivalent() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        try await makeFile(db, rootId: rootId, filename: "cake_stand.stl")

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: "cake stand")
        #expect(results.count == 1)
        #expect(results.first?.filename == "cake_stand.stl")
    }

    @Test func noQueryReturnsEverythingInPlainSortOrder() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        try await makeFile(db, rootId: rootId, filename: "old.stl", firstSeenAt: Date(timeIntervalSince1970: 1))
        try await makeFile(db, rootId: rootId, filename: "new.stl", firstSeenAt: Date(timeIntervalSince1970: 2))

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: nil, sort: .newest)
        #expect(results.map(\.filename) == ["new.stl", "old.stl"])
    }

    @Test func relevanceTiersPrefixBeforeSubstringRegardlessOfRecency() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        // Inserted in an order that would be wrong if relevance tiering weren't
        // applied (newest-first would put the substring match on top): "Top.stl" and
        // "top-plug-6mm.stl" both start with "top" (tier 1, prefix); "CandyStudTopper"
        // only contains "top" mid-string (tier 2, substring) despite being newest.
        try await makeFile(db, rootId: rootId, filename: "CandyStudTopper.stl", firstSeenAt: Date(timeIntervalSince1970: 3))
        try await makeFile(db, rootId: rootId, filename: "top-plug-6mm.stl", firstSeenAt: Date(timeIntervalSince1970: 2))
        try await makeFile(db, rootId: rootId, filename: "Top.stl", firstSeenAt: Date(timeIntervalSince1970: 1))

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: "top")
        // Both prefix matches (tier 1) sort before the substring match (tier 2); within
        // that shared tier, the default "newest" sort is still the tiebreaker.
        #expect(results.map(\.filename) == ["top-plug-6mm.stl", "Top.stl", "CandyStudTopper.stl"])
    }

    @Test func relevanceTiersExactBeforePrefix() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        // An exact match must win regardless of recency — "topper.stl" (prefix-only)
        // is inserted newer than "top.stl" (exact), which would sort first on
        // recency alone if tiering weren't applied.
        try await makeFile(db, rootId: rootId, filename: "topper.stl", firstSeenAt: Date(timeIntervalSince1970: 2))
        try await makeFile(db, rootId: rootId, filename: "top.stl", firstSeenAt: Date(timeIntervalSince1970: 1), displayName: "top")

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: "top")
        #expect(results.map(\.filename) == ["top.stl", "topper.stl"])
    }

    @Test func matchesPrintMetadataFieldsNotJustFilename() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, filename: "unrelated_name.stl")
        try await db.writer.write { conn in
            _ = try PrintMetadata(fileId: fileId, printerProfile: "Bambu Lab X1 Carbon", source: .manual).inserted(conn)
        }

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: "X1 Carbon")
        #expect(results.map(\.filename) == ["unrelated_name.stl"])
    }

    @Test func matchesPrintLogComments() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, filename: "gizmo.stl")
        try await db.writer.write { conn in
            _ = try PrintLog(fileId: fileId, printed: true, comments: "warped badly on the first layer").inserted(conn)
        }

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: "warped")
        #expect(results.map(\.filename) == ["gizmo.stl"])
    }

    @Test func structuredPhraseSearchMatchesNozzleDiameterWithTolerance() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let matchId = try await makeFile(db, rootId: rootId, filename: "match.stl")
        let missId = try await makeFile(db, rootId: rootId, filename: "miss.stl")
        try await db.writer.write { conn in
            _ = try PrintMetadata(
                fileId: matchId, settingsJson: PrintSettings(nozzleDiameterMM: 0.4), source: .autoExtractedGcode
            ).inserted(conn)
            _ = try PrintMetadata(
                fileId: missId, settingsJson: PrintSettings(nozzleDiameterMM: 0.6), source: .autoExtractedGcode
            ).inserted(conn)
        }

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: "0.4mm nozzle")
        #expect(results.map(\.filename) == ["match.stl"])
    }

    @Test func structuredPhraseSearchMatchesInfillPercent() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let matchId = try await makeFile(db, rootId: rootId, filename: "match.stl")
        try await db.writer.write { conn in
            _ = try PrintMetadata(
                fileId: matchId, settingsJson: PrintSettings(infillPercent: 20), source: .autoExtractedGcode
            ).inserted(conn)
        }

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: "20% infill")
        #expect(results.map(\.filename) == ["match.stl"])
    }

    @Test func plainSortIsUnaffectedWhenSearchingEmptyQuery() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        try await makeFile(db, rootId: rootId, filename: "a.stl", firstSeenAt: Date(timeIntervalSince1970: 10))
        try await makeFile(db, rootId: rootId, filename: "b.stl", firstSeenAt: Date(timeIntervalSince1970: 20))

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: "   ", sort: .oldest)
        #expect(results.map(\.filename) == ["a.stl", "b.stl"])
    }

    @Test func inactiveFilesAreExcluded() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fileId = try await makeFile(db, rootId: rootId, filename: "gone.stl")
        try await db.writer.write { conn in
            try conn.execute(sql: "UPDATE files SET status = 'missing' WHERE id = ?", arguments: [fileId])
        }

        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: nil)
        #expect(results.isEmpty)
    }

    @Test func extensionFilterNarrowsResults() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        try await makeFile(db, rootId: rootId, filename: "a.stl")
        try await makeFile(db, rootId: rootId, filename: "b.obj")

        var filters = LibraryFilters()
        filters.extensions = ["stl"]
        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: nil, filters: filters)

        #expect(results.map(\.filename) == ["a.stl"])
    }

    @Test func combiningTextQueryAndFilterBothApply() async throws {
        // Exercises named (:hasQuery/:normalizedQuery/etc.) and positional (filter `?`)
        // placeholders together in the same statement — the two styles must not
        // collide or silently drop bindings.
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        try await makeFile(db, rootId: rootId, filename: "widget.stl")
        try await makeFile(db, rootId: rootId, filename: "widget.obj")
        try await makeFile(db, rootId: rootId, filename: "other.stl")

        var filters = LibraryFilters()
        filters.extensions = ["stl"]
        let service = SearchService(writer: db.writer)
        let results = try await service.search(query: "widget", filters: filters)

        #expect(results.map(\.filename) == ["widget.stl"])
    }

    @Test func printedFilterYesAndNo() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let printedId = try await makeFile(db, rootId: rootId, filename: "printed.stl")
        try await makeFile(db, rootId: rootId, filename: "not-printed.stl")
        try await db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO print_log (file_id, printed) VALUES (?, 1)", arguments: [printedId])
        }

        let service = SearchService(writer: db.writer)

        var printedFilters = LibraryFilters()
        printedFilters.printed = .yes
        let printedResults = try await service.search(query: nil, filters: printedFilters)
        #expect(printedResults.map(\.filename) == ["printed.stl"])

        var notPrintedFilters = LibraryFilters()
        notPrintedFilters.printed = .no
        let notPrintedResults = try await service.search(query: nil, filters: notPrintedFilters)
        #expect(notPrintedResults.map(\.filename) == ["not-printed.stl"])
    }

    @Test func ratingFilterAndMaterialFilter() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let fiveStar = try await makeFile(db, rootId: rootId, filename: "five-star.stl")
        let threeStar = try await makeFile(db, rootId: rootId, filename: "three-star.stl")
        try await db.writer.write { conn in
            try conn.execute(sql: "INSERT INTO print_log (file_id, printed, rating) VALUES (?, 1, 5)", arguments: [fiveStar])
            try conn.execute(sql: "INSERT INTO print_log (file_id, printed, rating) VALUES (?, 1, 3)", arguments: [threeStar])
            try conn.execute(sql: "INSERT INTO print_metadata (file_id, material, source) VALUES (?, 'PLA', 'manual')", arguments: [fiveStar])
        }

        let service = SearchService(writer: db.writer)

        var ratingFilters = LibraryFilters()
        ratingFilters.ratings = [5]
        let ratingResults = try await service.search(query: nil, filters: ratingFilters)
        #expect(ratingResults.map(\.filename) == ["five-star.stl"])

        var materialFilters = LibraryFilters()
        materialFilters.material = "PLA"
        let materialResults = try await service.search(query: nil, filters: materialFilters)
        #expect(materialResults.map(\.filename) == ["five-star.stl"])
    }

    private func addToProject(_ db: SQLiteSpoolDatabase, projectId: Int64, fileId: Int64, status: String = "confirmed") async throws {
        try await db.writer.write { conn in
            try conn.execute(
                sql: "INSERT INTO project_files (project_id, file_id, status) VALUES (?, ?, ?)",
                arguments: [projectId, fileId, status]
            )
        }
    }

    @Test func collapsingReplacesAFullyMatchingProjectsFilesWithOneCard() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, filename: "widget-a.stl")
        let b = try await makeFile(db, rootId: rootId, filename: "widget-b.stl")
        let project = try await db.writer.write { conn in try Project(name: "Widget Kit").inserted(conn) }
        try await addToProject(db, projectId: project.id!, fileId: a)
        try await addToProject(db, projectId: project.id!, fileId: b)

        let service = SearchService(writer: db.writer)
        let rows = try await service.search(query: "widget")
        let items = try await db.writer.read { conn in try SearchService.collapseFullyMatchingProjects(rows: rows, in: conn) }

        #expect(items.count == 1)
        guard case .project(let card) = items.first else {
            Issue.record("expected a collapsed project card")
            return
        }
        #expect(card.projectId == project.id)
        #expect(card.fileCount == 2)
    }

    @Test func collapsingLeavesAPartiallyMatchingProjectAlone() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, filename: "widget-a.stl")
        let b = try await makeFile(db, rootId: rootId, filename: "other.stl")
        let project = try await db.writer.write { conn in try Project(name: "Widget Kit").inserted(conn) }
        try await addToProject(db, projectId: project.id!, fileId: a)
        try await addToProject(db, projectId: project.id!, fileId: b) // doesn't match "widget"

        let service = SearchService(writer: db.writer)
        let rows = try await service.search(query: "widget")
        let items = try await db.writer.read { conn in try SearchService.collapseFullyMatchingProjects(rows: rows, in: conn) }

        #expect(items.count == 1)
        guard case .file(let file) = items.first else {
            Issue.record("a partially-matching project's file must stay a plain file card")
            return
        }
        #expect(file.filename == "widget-a.stl")
    }

    @Test func collapsingNeverAppliesToASingleFileProject() async throws {
        // matching_count > 1 is required — a "project" of one collapsing into a card
        // is no different from just showing the file itself.
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, filename: "widget-a.stl")
        let project = try await db.writer.write { conn in try Project(name: "Widget Kit").inserted(conn) }
        try await addToProject(db, projectId: project.id!, fileId: a)

        let service = SearchService(writer: db.writer)
        let rows = try await service.search(query: "widget")
        let items = try await db.writer.read { conn in try SearchService.collapseFullyMatchingProjects(rows: rows, in: conn) }

        #expect(items.count == 1)
        guard case .file = items.first else {
            Issue.record("a single-file project must never collapse")
            return
        }
    }

    @Test func collapsingIgnoresSuggestedNotYetConfirmedMemberships() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, filename: "widget-a.stl")
        let b = try await makeFile(db, rootId: rootId, filename: "widget-b.stl")
        let project = try await db.writer.write { conn in try Project(name: "Widget Kit").inserted(conn) }
        try await addToProject(db, projectId: project.id!, fileId: a, status: "confirmed")
        try await addToProject(db, projectId: project.id!, fileId: b, status: "suggested")

        let service = SearchService(writer: db.writer)
        let rows = try await service.search(query: "widget")
        let items = try await db.writer.read { conn in try SearchService.collapseFullyMatchingProjects(rows: rows, in: conn) }

        #expect(items.count == 2, "only one confirmed member — not enough to collapse, and the suggested one is invisible to this at all")
        for item in items {
            guard case .file = item else {
                Issue.record("neither row should collapse")
                return
            }
        }
    }

    @Test func collapsingPicksTheAlphabeticallyFirstProjectWhenAFileBelongsToTwoFullyMatchingOnes() async throws {
        let db = try SQLiteSpoolDatabase(path: nil)
        let rootId = try await makeRoot(db)
        let a = try await makeFile(db, rootId: rootId, filename: "widget-a.stl")
        let b = try await makeFile(db, rootId: rootId, filename: "widget-b.stl")
        let c = try await makeFile(db, rootId: rootId, filename: "widget-c.stl")
        let projectA = try await db.writer.write { conn in try Project(name: "Alpha Kit").inserted(conn) }
        let projectZ = try await db.writer.write { conn in try Project(name: "Zebra Kit").inserted(conn) }
        // `a` belongs to both — Alpha Kit (2 members, both matching) and Zebra Kit
        // (2 members, both matching) — Alpha must win since it sorts first by name.
        try await addToProject(db, projectId: projectA.id!, fileId: a)
        try await addToProject(db, projectId: projectA.id!, fileId: b)
        try await addToProject(db, projectId: projectZ.id!, fileId: a)
        try await addToProject(db, projectId: projectZ.id!, fileId: c)

        let service = SearchService(writer: db.writer)
        let rows = try await service.search(query: "widget")
        let items = try await db.writer.read { conn in try SearchService.collapseFullyMatchingProjects(rows: rows, in: conn) }

        let cards = items.compactMap { item -> ProjectSearchCard? in
            if case .project(let card) = item { return card }
            return nil
        }
        #expect(cards.count == 2)
        #expect(Set(cards.map(\.name)) == ["Alpha Kit", "Zebra Kit"])
        let alpha = try #require(cards.first { $0.name == "Alpha Kit" })
        #expect(alpha.fileCount == 2, "keeps both its own members, including the shared file `a`")
        let zebra = try #require(cards.first { $0.name == "Zebra Kit" })
        #expect(zebra.fileCount == 2, "Zebra's own count is unaffected — only which card the shared file renders under changes")
    }
}
