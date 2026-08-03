import Combine
import Foundation
import GRDB
import SpoolCore

/// Drives the browse grid off `ValueObservation` — SwiftUI sees new/updated rows as
/// ingestion and rendering write them, with no manual refresh/polling needed. This is
/// the payoff of going single-process: the source app's browse page needed an htmx
/// live-search round trip to get this; here it falls out of GRDB for free. Search text,
/// sort, and structured filters all restart the observation with `SearchService.buildQuery`'s
/// SQL, so results stay live even while filtered, not just while browsing unfiltered.
@MainActor
final class LibraryViewModel: ObservableObject {
    @Published private(set) var items: [LibrarySearchItem] = []
    @Published var searchQuery: String = "" {
        didSet { restartObservation() }
    }
    @Published var sortOrder: LibrarySortOrder = .newest {
        didSet { restartObservation() }
    }
    @Published var filters: LibraryFilters = LibraryFilters() {
        didSet { restartObservation() }
    }

    // Populated once at start() — the finite/known-value filter option lists (which
    // extensions/tags/materials/printers/slicers actually appear anywhere in the
    // library right now), for the filter menu to offer.
    @Published private(set) var availableTags: [Tag] = []
    @Published private(set) var availableMaterials: [String] = []
    @Published private(set) var availablePrinterProfiles: [String] = []
    @Published private(set) var availableSlicers: [String] = []

    private var writer: (any DatabaseWriter)?
    private var observationTask: Task<Void, Never>?

    func start(writer: any DatabaseWriter, environment: AppEnvironment) {
        guard self.writer == nil else { return }
        self.writer = writer
        restartObservation()
        Task { await loadFilterOptions(environment: environment) }
    }

    private func loadFilterOptions(environment: AppEnvironment) async {
        async let tags = environment.tags.allTags()
        async let materials = environment.search.distinctMaterials()
        async let printers = environment.search.distinctPrinterProfiles()
        async let slicers = environment.search.distinctSlicers()
        availableTags = (try? await tags) ?? []
        availableMaterials = (try? await materials) ?? []
        availablePrinterProfiles = (try? await printers) ?? []
        availableSlicers = (try? await slicers) ?? []
    }

    private func restartObservation() {
        guard let writer else { return }
        observationTask?.cancel()

        let query = searchQuery
        let sort = sortOrder
        let filters = filters
        // Collapsing runs unconditionally, not just while a search/filter is active —
        // matches the source app's own `search_files` exactly: a plain unfiltered
        // browse still collapses every project whose files are all simply active
        // (which is nearly always true), so the default grid already reads as
        // "projects, then loose files" rather than one flat file wall.
        let observation = ValueObservation.tracking { db in
            let (sql, arguments) = SearchService.buildQuery(query: query, sort: sort, filters: filters)
            let rows = try SpoolFile.fetchAll(db, sql: sql, arguments: arguments)
            return try SearchService.collapseFullyMatchingProjects(rows: rows, in: db)
        }
        // See AppEnvironment/RenderJobHandler history: `.values(in:)` is the
        // Swift-Concurrency-safe way to drive a ValueObservation, not the closure-based
        // `.start(in:onError:onChange:)`, which crashes when called from a Task.
        observationTask = Task { [weak self] in
            do {
                for try await items in observation.values(in: writer) {
                    guard !Task.isCancelled else { return }
                    self?.items = items
                }
            } catch {
                // Observation ended/cancelled (e.g. superseded by a newer search) —
                // nothing to recover here.
            }
        }
    }
}
