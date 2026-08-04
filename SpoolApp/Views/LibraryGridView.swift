import SpoolCore
import SwiftUI

private enum LibraryViewMode: String {
    case grid, list
}

struct LibraryGridView: View {
    /// So tapping a collapsed project card navigates the sidebar to that project.
    @Binding var selection: SidebarSelection?
    /// Owned by `ContentView` — lets the keyboard "open" action push a destination
    /// exactly the way clicking a `NavigationLink` does, from the same stack.
    @Binding var navigationPath: NavigationPath
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var rootAccess: RootAccessManager
    @EnvironmentObject private var rootsViewModel: RootsViewModel
    @EnvironmentObject private var projectsViewModel: ProjectsViewModel
    @StateObject private var libraryViewModel = LibraryViewModel()
    @AppStorage("libraryViewMode") private var viewModeRaw = LibraryViewMode.grid.rawValue
    @State private var isSelecting = false
    @State private var selectedFileIds: Set<Int64> = []
    @State private var showingDeleteConfirmation = false
    /// The keyboard-focused item, independent of click-based navigation — lets arrow
    /// keys move a visible focus ring around the grid the way Finder's icon view does,
    /// without requiring a click first.
    @State private var focusedItemId: String?
    @State private var gridContentWidth: CGFloat = 0
    @State private var isDropTargeted = false
    @State private var importAlertMessage: String?
    /// Populated on demand (first time a project is selected-all'd or toggled), not
    /// eagerly for every visible project card — `ProjectSearchCard` itself carries no
    /// file-id list, so this is the one place that cost is paid, and only once per
    /// project per session since membership doesn't change under the grid's feet.
    @State private var projectFileIdsCache: [Int64: [Int64]] = [:]

    private var viewMode: LibraryViewMode { LibraryViewMode(rawValue: viewModeRaw) ?? .grid }

    private static let columnMinWidth: CGFloat = 140
    private static let columnSpacing: CGFloat = 12
    private let columns = [GridItem(.adaptive(minimum: columnMinWidth, maximum: 200), spacing: columnSpacing)]

    /// Mirrors the `.adaptive` grid's own column math closely enough for arrow-key
    /// up/down to land in the visually correct row — SwiftUI doesn't expose the
    /// resolved column count for an adaptive `GridItem` directly.
    private var columnCount: Int {
        max(1, Int((gridContentWidth + Self.columnSpacing) / (Self.columnMinWidth + Self.columnSpacing)))
    }

    var body: some View {
        Group {
            if libraryViewModel.items.isEmpty {
                if !libraryViewModel.searchQuery.isEmpty {
                    ContentUnavailableView.search(text: libraryViewModel.searchQuery)
                } else if !libraryViewModel.filters.isEmpty {
                    ContentUnavailableView(
                        "No files match these filters",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Try clearing a filter or two.")
                    )
                } else {
                    if rootsViewModel.roots.isEmpty {
                        // The most likely reason the grid is empty on first launch: no
                        // folder has been granted yet. A toolbar-only affordance for
                        // that (a small icon-only "+" button) turned out to be easy to
                        // miss entirely — this button is impossible to miss.
                        ContentUnavailableView {
                            Label("Grant a folder to get started", systemImage: "shippingbox")
                        } description: {
                            Text("Spool watches a folder you choose and indexes any 3D-printing files inside it automatically.")
                        } actions: {
                            Button("Add Drop Folder…") {
                                Task { await rootsViewModel.addRoot(kind: .dropFolder, label: "Drop Folder") }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView(
                            "Your library will appear here",
                            systemImage: "shippingbox",
                            description: Text("Files in your granted folders are hashed and thumbnailed automatically — this updates live as that happens.")
                        )
                    }
                }
            } else {
                switch viewMode {
                case .grid: gridBody
                case .list: listBody
                }
            }
        }
        .overlay {
            // Standard macOS "something will land here" affordance (Mail, Photos) —
            // shown for the whole drop target, not just wherever the pointer happens
            // to be over a specific card.
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .navigationDestination(for: Int64.self) { fileDetailDestination(forFileId: $0) }
        .onKeyPress(.return) { openFocusedItem() ? .handled : .ignored }
        .onKeyPress(.delete) { deleteFocusedOrSelected() ? .handled : .ignored }
        .onKeyPress(.deleteForward) { deleteFocusedOrSelected() ? .handled : .ignored }
        // See ContentView/AdminView/etc.'s identical fix — `.constant()` here is a
        // real, confirmed trigger for "Publishing changes from within view updates is
        // not allowed".
        .alert("Couldn't Import", isPresented: Binding(
            get: { importAlertMessage != nil },
            set: { if !$0 { importAlertMessage = nil } }
        ), actions: {
            Button("OK") { importAlertMessage = nil }
        }, message: { Text(importAlertMessage ?? "") })
        .searchable(text: $libraryViewModel.searchQuery, prompt: "Search filenames, tags, print settings…")
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionActionBar
            }
        }
        .toolbar {
            ToolbarItem {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { selectedFileIds = [] }
                }
                .help(isSelecting ? "Exit selection" : "Select multiple files to delete or add to a project")
            }
            if isSelecting {
                ToolbarItem {
                    Button(selectedFileIds.isEmpty ? "Select All" : "Deselect All") {
                        if selectedFileIds.isEmpty {
                            Task { await selectAll() }
                        } else {
                            selectedFileIds = []
                        }
                    }
                    .help(selectedFileIds.isEmpty
                        ? "Select every file shown, including every file in a matching project"
                        : "Clear the current selection")
                    .disabled(libraryViewModel.items.isEmpty)
                }
            }
            ToolbarItem {
                FilterMenuButton(libraryViewModel: libraryViewModel)
            }
            ToolbarItem {
                Picker("View", selection: $viewModeRaw) {
                    Image(systemName: "square.grid.2x2").tag(LibraryViewMode.grid.rawValue).accessibilityLabel("Grid view")
                    Image(systemName: "list.bullet").tag(LibraryViewMode.list.rawValue).accessibilityLabel("List view")
                }
                .pickerStyle(.segmented)
                .help("Switch between grid and list view")
            }
            ToolbarItem {
                Picker("Sort", selection: $libraryViewModel.sortOrder) {
                    Text("Newest").tag(LibrarySortOrder.newest)
                    Text("Oldest").tag(LibrarySortOrder.oldest)
                    Text("Name (A–Z)").tag(LibrarySortOrder.nameAsc)
                    Text("Name (Z–A)").tag(LibrarySortOrder.nameDesc)
                    Text("Largest").tag(LibrarySortOrder.sizeDesc)
                    Text("Smallest").tag(LibrarySortOrder.sizeAsc)
                }
                .help("Sort order")
            }
        }
        .task { libraryViewModel.start(writer: environment.database.writer, environment: environment) }
        .task { await projectsViewModel.load() }
        .confirmationDialog(
            "Delete \(selectedFileIds.count) file\(selectedFileIds.count == 1 ? "" : "s")?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { Task { await deleteSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Moves the selected files to the Trash. Files in a read-only Library folder are skipped.")
        }
    }

    private var selectionActionBar: some View {
        HStack {
            Text("\(selectedFileIds.count) selected").foregroundStyle(.secondary)
            Spacer()
            Menu("Add to Project") {
                ForEach(projectsViewModel.allProjects) { project in
                    Button(project.name) { Task { await addSelected(toProjectId: project.id!) } }
                }
            }
            .disabled(selectedFileIds.isEmpty || projectsViewModel.allProjects.isEmpty)
            .fixedSize()
            Button("Delete…", role: .destructive) { showingDeleteConfirmation = true }
                .disabled(selectedFileIds.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private func toggleSelection(_ fileId: Int64?) {
        guard let fileId else { return }
        if selectedFileIds.contains(fileId) {
            selectedFileIds.remove(fileId)
        } else {
            selectedFileIds.insert(fileId)
        }
    }

    /// A project card in the grid is a collapsed stand-in for every file inside it —
    /// membership, not the card itself, so "selecting" one means resolving and adding
    /// its actual file ids, same as if you'd multi-selected them individually.
    private func fileIds(forProjectId projectId: Int64) async -> [Int64] {
        if let cached = projectFileIdsCache[projectId] { return cached }
        let files = (try? await environment.projects.confirmedFiles(inProjectId: projectId)) ?? []
        let ids = files.compactMap(\.id)
        projectFileIdsCache[projectId] = ids
        return ids
    }

    private func toggleProjectSelection(_ card: ProjectSearchCard) async {
        let ids = await fileIds(forProjectId: card.projectId)
        guard !ids.isEmpty else { return }
        if ids.allSatisfy({ selectedFileIds.contains($0) }) {
            selectedFileIds.subtract(ids)
        } else {
            selectedFileIds.formUnion(ids)
        }
    }

    private func selectAll() async {
        var ids: Set<Int64> = []
        for item in libraryViewModel.items {
            switch item {
            case .file(let file):
                if let id = file.id { ids.insert(id) }
            case .project(let card):
                ids.formUnion(await fileIds(forProjectId: card.projectId))
            }
        }
        selectedFileIds = ids
    }

    private func deleteSelected() async {
        _ = try? await environment.files.deleteFiles(fileIds: Array(selectedFileIds))
        selectedFileIds = []
        isSelecting = false
    }

    /// A project card that's fully checked off represents the *project*, not a loose
    /// pile of its files — "Add to Project" on that selection nests it as a
    /// sub-project (same operation as `ProjectsView`'s "Move to Another Project"),
    /// rather than just cross-listing its files as members of the target too. Only
    /// files that were selected individually (not swept in by a fully-selected
    /// project) get added as plain members.
    private func addSelected(toProjectId projectId: Int64) async {
        let fullySelectedProjectIds = libraryViewModel.items.compactMap { item -> Int64? in
            guard case .project(let card) = item,
                  let ids = projectFileIdsCache[card.projectId], !ids.isEmpty,
                  ids.allSatisfy({ selectedFileIds.contains($0) }) else { return nil }
            return card.projectId
        }
        let nestedFileIds = Set(fullySelectedProjectIds.flatMap { projectFileIdsCache[$0] ?? [] })
        let looseFileIds = selectedFileIds.subtracting(nestedFileIds)

        var didReparent = false
        for sourceProjectId in fullySelectedProjectIds {
            // Same cycle guard as `MoveProjectSheet`'s candidate list — nesting a
            // project into itself or one of its own descendants would corrupt the tree.
            guard sourceProjectId != projectId,
                  !projectsViewModel.descendantIds(of: sourceProjectId).contains(projectId) else { continue }
            try? await environment.projects.reparent(projectId: sourceProjectId, toParentId: projectId)
            didReparent = true
        }
        if !looseFileIds.isEmpty {
            try? await environment.projects.addFiles(fileIds: Array(looseFileIds), toProjectId: projectId)
        }
        // `ProjectsViewModel.allProjects` is a plain loaded-once snapshot (see its own
        // `reparent(_:toParentId:)`) — going through `environment.projects` directly
        // above bypasses that cache, so the sidebar tree would keep showing the
        // now-nested project at the top level until something else happened to reload it.
        if didReparent { await projectsViewModel.load() }
        selectedFileIds = []
        isSelecting = false
    }

    /// Files dropped from Finder land in the real drop-folder directory (copied, never
    /// moved — the source stays untouched, matching how importing into Photos/Mail
    /// works) and are staged immediately rather than waiting for the next live-watch
    /// settle cycle to notice them.
    private func handleDroppedFiles(_ urls: [URL]) {
        guard let dropRoot = rootsViewModel.roots.first(where: { $0.kind == .dropFolder }),
              let dropRootId = dropRoot.id,
              let dropRootURL = rootAccess.url(forRootId: dropRootId) else {
            importAlertMessage = "Grant a drop folder before dragging files in — Spool needs somewhere to put them."
            return
        }
        Task {
            for url in urls {
                await importDroppedFile(url, into: dropRoot, dropFolderURL: dropRootURL)
            }
        }
    }

    private func importDroppedFile(_ sourceURL: URL, into dropRoot: WatchedRoot, dropFolderURL: URL) async {
        let fileManager = FileManager.default
        var destination = dropFolderURL.appendingPathComponent(sourceURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            let stem = sourceURL.deletingPathExtension().lastPathComponent
            let ext = sourceURL.pathExtension
            var suffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                let candidate = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
                destination = dropFolderURL.appendingPathComponent(candidate)
                suffix += 1
            }
        }
        do {
            try fileManager.copyItem(at: sourceURL, to: destination)
            _ = try? await environment.backfill.stageIfNew(path: destination.path, root: dropRoot, rootURL: dropFolderURL)
        } catch {
            importAlertMessage = "Couldn't copy \(sourceURL.lastPathComponent) into your drop folder: \(error.localizedDescription)"
        }
    }

    private var gridBody: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Self.columnSpacing) {
                    ForEach(libraryViewModel.items) { item in
                        switch item {
                        case .file(let file):
                            if isSelecting {
                                Button(action: { toggleSelection(file.id) }) {
                                    FileCardView(file: file, thumbnailsDirectory: environment.thumbnailsDirectory)
                                        .overlay(alignment: .topTrailing) { selectionBadge(for: file.id) }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(file.displayName ?? file.filename)
                                .accessibilityAddTraits(selectedFileIds.contains(file.id ?? -1) ? [.isSelected] : [])
                            } else {
                                NavigationLink(value: file.id ?? -1) {
                                    FileCardView(
                                        file: file, thumbnailsDirectory: environment.thumbnailsDirectory,
                                        isFocused: item.id == focusedItemId
                                    )
                                }
                                .buttonStyle(.plain)
                                .contextMenu { fileContextMenu(for: file) }
                                .onDrag { fileDragItemProvider(for: file) }
                            }
                        case .project(let card):
                            if isSelecting {
                                Button(action: { Task { await toggleProjectSelection(card) } }) {
                                    ProjectSearchResultCard(
                                        card: card, thumbnailsDirectory: environment.thumbnailsDirectory,
                                        isFocused: item.id == focusedItemId
                                    )
                                    .overlay(alignment: .topTrailing) { projectSelectionBadge(for: card) }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(card.name), \(card.fileCount) files")
                            } else {
                                Button(action: { selection = .project(card.projectId) }) {
                                    ProjectSearchResultCard(
                                        card: card, thumbnailsDirectory: environment.thumbnailsDirectory,
                                        isFocused: item.id == focusedItemId
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .onAppear { gridContentWidth = proxy.size.width - 32 }
            .onChange(of: proxy.size.width) { _, newValue in gridContentWidth = newValue - 32 }
        }
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { moveFocus($0) }
    }

    /// Mimics Finder's icon-view keyboard navigation: arrow keys move a focus ring
    /// (independent of click/selection state), Return opens or toggles the focused
    /// item, Delete removes it — none of which a `LazyVGrid` of buttons gets for free
    /// the way `List` does.
    private func moveFocus(_ direction: MoveCommandDirection) {
        let ids = libraryViewModel.items.map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = focusedItemId, let currentIndex = ids.firstIndex(of: current) else {
            focusedItemId = ids.first
            return
        }
        var newIndex = currentIndex
        switch direction {
        case .left: newIndex -= 1
        case .right: newIndex += 1
        case .up: newIndex -= columnCount
        case .down: newIndex += columnCount
        @unknown default: break
        }
        focusedItemId = ids[min(max(newIndex, 0), ids.count - 1)]
    }

    private func openFocusedItem() -> Bool {
        guard let focusedItemId, let item = libraryViewModel.items.first(where: { $0.id == focusedItemId }) else { return false }
        switch item {
        case .file(let file):
            if isSelecting {
                toggleSelection(file.id)
            } else {
                navigationPath.append(file.id ?? -1)
            }
        case .project(let card):
            if isSelecting {
                Task { await toggleProjectSelection(card) }
            } else {
                selection = .project(card.projectId)
            }
        }
        return true
    }

    private func deleteFocusedOrSelected() -> Bool {
        if isSelecting {
            guard !selectedFileIds.isEmpty else { return false }
            showingDeleteConfirmation = true
            return true
        }
        guard let focusedItemId,
              case .file(let file) = libraryViewModel.items.first(where: { $0.id == focusedItemId }),
              let fileId = file.id else { return false }
        selectedFileIds = [fileId]
        showingDeleteConfirmation = true
        return true
    }

    /// A drag payload Finder/a slicer's Dock icon recognizes as a real file, not just
    /// text — `NSItemProvider(contentsOf:)` registers the actual file-URL UTType,
    /// which is what makes dragging a card onto Finder or a Dock icon behave exactly
    /// like dragging the real file would.
    private func fileDragItemProvider(for file: SpoolFile) -> NSItemProvider {
        NSItemProvider(contentsOf: URL(fileURLWithPath: file.path)) ?? NSItemProvider()
    }

    @ViewBuilder
    private func fileDetailDestination(forFileId fileId: Int64) -> some View {
        let match = libraryViewModel.items.compactMap { item -> SpoolFile? in
            if case .file(let file) = item, file.id == fileId { return file }
            return nil
        }.first
        if let file = match {
            FileDetailView(file: file, environment: environment)
        }
    }

    /// The standard Finder-style right-click menu every item representing a real file
    /// on disk should offer — "Open With" and "Reveal in Finder" above all, since
    /// there's otherwise no way to get to the file itself without leaving Spool.
    @ViewBuilder
    private func fileContextMenu(for file: SpoolFile) -> some View {
        let fileURL = URL(fileURLWithPath: file.path)
        if environment.detectedApps.isEmpty {
            Button("Open") { OpenInAppService.openWithDefaultApplication(fileURL: fileURL) }
        } else {
            Menu("Open With") {
                ForEach(environment.detectedApps) { app in
                    Button(app.name) { OpenInAppService.open(fileURL: fileURL, in: app) }
                }
                Divider()
                Button("Default Application") { OpenInAppService.openWithDefaultApplication(fileURL: fileURL) }
            }
        }
        Button("Reveal in Finder") { OpenInAppService.revealInFinder(fileURL: fileURL) }
        Divider()
        Button("Delete…", role: .destructive) {
            selectedFileIds = Set([file.id].compactMap { $0 })
            showingDeleteConfirmation = true
        }
    }

    @ViewBuilder
    private func selectionBadge(for fileId: Int64?) -> some View {
        let isSelected = fileId.map { selectedFileIds.contains($0) } ?? false
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, isSelected ? Color.accentColor : Color.secondary)
            .background(Circle().fill(isSelected ? Color.clear : .white).padding(2))
            .padding(6)
    }

    /// "Selected" for a project card means every one of its files is currently in
    /// `selectedFileIds` — read from `projectFileIdsCache` only, so this stays a plain
    /// synchronous computed view; the cache is populated the first time this project
    /// is toggled or a "Select All" pass runs, and stays unselected-looking until then.
    @ViewBuilder
    private func projectSelectionBadge(for card: ProjectSearchCard) -> some View {
        let isSelected = projectFileIdsCache[card.projectId].map { ids in
            !ids.isEmpty && ids.allSatisfy { selectedFileIds.contains($0) }
        } ?? false
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, isSelected ? Color.accentColor : Color.secondary)
            .background(Circle().fill(isSelected ? Color.clear : .white).padding(2))
            .padding(6)
    }

    private var listBody: some View {
        // The `selection:` binding is what gets List's native arrow-key/type-ahead
        // navigation for free — the same `focusedItemId` the grid drives manually,
        // so Return/Delete behave identically regardless of which view mode is active.
        List(libraryViewModel.items, selection: $focusedItemId) { item in
            switch item {
            case .file(let file):
                if isSelecting {
                    Button(action: { toggleSelection(file.id) }) {
                        HStack {
                            selectionBadge(for: file.id)
                            FileListRow(file: file, thumbnailsDirectory: environment.thumbnailsDirectory)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(file.displayName ?? file.filename)
                    .accessibilityAddTraits(selectedFileIds.contains(file.id ?? -1) ? [.isSelected] : [])
                } else {
                    NavigationLink(value: file.id ?? -1) {
                        FileListRow(file: file, thumbnailsDirectory: environment.thumbnailsDirectory)
                    }
                    .contextMenu { fileContextMenu(for: file) }
                    .onDrag { fileDragItemProvider(for: file) }
                }
            case .project(let card):
                if isSelecting {
                    Button(action: { Task { await toggleProjectSelection(card) } }) {
                        HStack {
                            projectSelectionBadge(for: card)
                            ProjectSearchResultListRow(card: card, thumbnailsDirectory: environment.thumbnailsDirectory)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(card.name), \(card.fileCount) files")
                } else {
                    Button(action: { selection = .project(card.projectId) }) {
                        ProjectSearchResultListRow(card: card, thumbnailsDirectory: environment.thumbnailsDirectory)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.inset)
    }
}

/// A collapsed "this whole project matched" result — thumbnail collage, name, ext
/// badges, file count. Shares its visual language with `FileCardView` (same corner
/// radius, same reserved-height text rows) so it reads as a natural part of the grid,
/// not a foreign component dropped in.
private struct ProjectSearchResultCard: View {
    let card: ProjectSearchCard
    let thumbnailsDirectory: URL
    var isFocused: Bool = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                // `Color.clear` as the sizing scaffold, with the real content only ever
                // *overlaid* on top — a resizable Image or a LazyVGrid of images each
                // reports a different intrinsic size depending on how many thumbnails
                // there are, and letting any of that leak into the `aspectRatio(1, ...)`
                // computation is exactly what made project cards a different, and
                // inconsistent-between-projects, size from plain file cards. `Color.clear`
                // always reports the same fully-flexible intrinsic size, so this box is
                // *always* exactly the grid column's width, full stop.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { collage }
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("PROJECT")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(card.color.swiftUIColor.opacity(0.85)))
                    .foregroundStyle(.white)
                    .padding(6)
            }
            Text(card.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text("\(card.fileCount) files").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(isHovering ? 0.5 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: isFocused ? 2 : 0))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .help("Every matching file in this result belongs to “\(card.name)” — open the project to see them all")
    }

    @ViewBuilder
    private var collage: some View {
        if card.thumbnailPaths.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(.secondary)
                Text("\(card.fileCount) files").font(.caption2).foregroundStyle(.secondary)
            }
        } else if card.thumbnailPaths.count == 1 {
            thumbImage(card.thumbnailPaths[0])
                .aspectRatio(contentMode: .fit)
                .padding(8)
        } else {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                ForEach(card.thumbnailPaths, id: \.self) { path in
                    thumbImage(path).aspectRatio(1, contentMode: .fill).clipped()
                }
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private func thumbImage(_ path: String) -> some View {
        if let image = NSImage(contentsOfFile: thumbnailsDirectory.appendingPathComponent(path).path) {
            Image(nsImage: image).resizable()
        } else {
            Color.clear
        }
    }
}

private struct ProjectSearchResultListRow: View {
    let card: ProjectSearchCard
    let thumbnailsDirectory: URL

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let path = card.thumbnailPaths.first,
                   let image = NSImage(contentsOfFile: thumbnailsDirectory.appendingPathComponent(path).path) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(4)
                } else {
                    Image(systemName: "folder").font(.system(size: 16)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).lineLimit(1)
                Text("Project").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(card.fileCount) files").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Shared render-status-to-icon/color/description mapping — the grid card, list row,
/// and file detail header all need to agree on what "failed" vs. "unsupported" vs.
/// "pending" look like.
enum RenderStatusPresentation {
    static func icon(for status: FileRenderStatus) -> String {
        switch status {
        case .pending, .rendering: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        case .unsupported: return "questionmark.square.dashed"
        case .done: return "cube"
        }
    }

    static func color(for status: FileRenderStatus) -> Color {
        switch status {
        case .pending, .rendering: return .secondary
        case .failed: return .red
        case .unsupported: return .secondary
        case .done: return .secondary
        }
    }

    static func tooltip(for file: SpoolFile) -> String? {
        switch file.renderStatus {
        case .failed:
            let label = RenderErrorLabel.label(for: file.renderError)
            return file.renderError.map { "\(label): \($0)" } ?? label
        case .unsupported:
            return "Spool can't generate a preview for .\(file.ext) files"
        case .pending, .rendering:
            return "Waiting to be processed…"
        case .done:
            return nil
        }
    }
}

/// A static hourglass reads identically whether a render job is actively running or
/// stuck — `.symbolEffect(.pulse)` (the real SF Symbols mechanism for "an ongoing
/// process," not a hand-rolled opacity/rotation animation) makes pending/rendering
/// files visibly distinct from a genuinely idle state at a glance. Not `private` — used
/// by `FileDetailView` too, which was still using a bare `Image` (no pulse) before.
struct RenderStatusIcon: View {
    let status: FileRenderStatus
    let size: CGFloat

    var body: some View {
        Image(systemName: RenderStatusPresentation.icon(for: status))
            .font(.system(size: size))
            .foregroundStyle(RenderStatusPresentation.color(for: status))
            .symbolEffect(.pulse, isActive: status == .pending || status == .rendering)
    }
}

struct FileCardView: View {
    let file: SpoolFile
    let thumbnailsDirectory: URL
    var isFocused: Bool = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Same `Color.clear` sizing scaffold as `ProjectSearchResultCard` — keeps
            // every card's thumbnail box exactly the grid column's width regardless of
            // what's inside it, so a mixed grid of file and project cards lines up.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { thumbnail }
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(file.displayName ?? file.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            // Always reserve this line's height, even when there's no bbox yet (a
            // pending/failed/STEP-without-a-render file) — otherwise cards with and
            // without a dimensions line end up different heights, and a grid row with
            // a mix of the two looks ragged instead of evenly aligned.
            Text(dimensionsLabel ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(dimensionsLabel == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        // Finder/Photos-style hover feedback — a plain grid of tappable cards gives no
        // other indication anything under the pointer is interactive until clicked.
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(isHovering ? 0.5 : 0)))
        // The keyboard-focus ring — same idea as Finder's icon view: a visible outline
        // independent of hover/click, so arrow-key navigation is actually legible.
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: isFocused ? 2 : 0))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .help(RenderStatusPresentation.tooltip(for: file) ?? "")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = file.thumbnailPath,
           let image = NSImage(contentsOfFile: thumbnailsDirectory.appendingPathComponent(path).path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(8)
        } else {
            VStack(spacing: 6) {
                RenderStatusIcon(status: file.renderStatus, size: 30)
                Text(file.ext.uppercased()).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var dimensionsLabel: String? {
        guard let x = file.bboxX, let y = file.bboxY, let z = file.bboxZ else { return nil }
        return String(format: "%.0f × %.0f × %.0f mm", x, y, z)
    }
}

private struct FileListRow: View {
    let file: SpoolFile
    let thumbnailsDirectory: URL

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(file.displayName ?? file.filename).lineLimit(1)
                Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if let dims = dimensionsLabel {
                Text(dims).font(.caption).foregroundStyle(.secondary)
            }
            Text(sizeLabel).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(RenderStatusPresentation.tooltip(for: file) ?? "")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let path = file.thumbnailPath,
           let image = NSImage(contentsOfFile: thumbnailsDirectory.appendingPathComponent(path).path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(4)
        } else {
            RenderStatusIcon(status: file.renderStatus, size: 16)
        }
    }

    private var dimensionsLabel: String? {
        guard let x = file.bboxX, let y = file.bboxY, let z = file.bboxZ else { return nil }
        return String(format: "%.0f × %.0f × %.0f mm", x, y, z)
    }

    private var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file)
    }
}

/// Filter icon button + popover — matches the standard macOS "funnel" filter affordance
/// (Mail, Photos): a plain outline icon when nothing's filtered, filled + tinted the
/// moment any filter is active, so the button itself communicates state at a glance
/// without needing a separate badge.
private struct FilterMenuButton: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    @State private var isPresented = false

    var body: some View {
        Button(action: { isPresented = true }) {
            Image(systemName: libraryViewModel.filters.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Filter by type, tag, rating, print status, and print settings")
        .accessibilityLabel(libraryViewModel.filters.isEmpty ? "Filter" : "Filter (active)")
        .popover(isPresented: $isPresented) {
            FilterPopoverContent(libraryViewModel: libraryViewModel)
        }
    }
}

private struct FilterPopoverContent: View {
    @ObservedObject var libraryViewModel: LibraryViewModel

    var body: some View {
        Form {
            Section("File Type") {
                ForEach(ModelExtension.allCases, id: \.self) { ext in
                    Toggle(ext.rawValue.uppercased(), isOn: extensionBinding(ext.rawValue))
                }
            }
            if !libraryViewModel.availableTags.isEmpty {
                Section("Tags") {
                    ForEach(libraryViewModel.availableTags) { tag in
                        Toggle(tag.name, isOn: tagBinding(tag.name))
                    }
                }
            }
            Section("Rating") {
                ForEach((1...5).reversed(), id: \.self) { star in
                    Toggle(isOn: ratingBinding(star)) {
                        HStack(spacing: 1) {
                            ForEach(0..<star, id: \.self) { _ in
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            }
                        }
                    }
                    .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                }
            }
            Section("Printed") {
                Picker("", selection: $libraryViewModel.filters.printed) {
                    Text("Any").tag(LibraryFilters.PrintedFilter.any)
                    Text("Printed").tag(LibraryFilters.PrintedFilter.yes)
                    Text("Not Printed").tag(LibraryFilters.PrintedFilter.no)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
            if !libraryViewModel.availableMaterials.isEmpty {
                Section("Material") {
                    Picker("Material", selection: $libraryViewModel.filters.material) {
                        Text("Any").tag(String?.none)
                        ForEach(libraryViewModel.availableMaterials, id: \.self) { material in
                            Text(material).tag(String?.some(material))
                        }
                    }
                    .labelsHidden()
                }
            }
            if !libraryViewModel.availablePrinterProfiles.isEmpty {
                Section("Printer") {
                    Picker("Printer", selection: $libraryViewModel.filters.printerProfile) {
                        Text("Any").tag(String?.none)
                        ForEach(libraryViewModel.availablePrinterProfiles, id: \.self) { printer in
                            Text(printer).tag(String?.some(printer))
                        }
                    }
                    .labelsHidden()
                }
            }
            if !libraryViewModel.availableSlicers.isEmpty {
                Section("Slicer") {
                    Picker("Slicer", selection: $libraryViewModel.filters.slicer) {
                        Text("Any").tag(String?.none)
                        ForEach(libraryViewModel.availableSlicers, id: \.self) { slicer in
                            Text(slicer).tag(String?.some(slicer))
                        }
                    }
                    .labelsHidden()
                }
            }
            if !libraryViewModel.filters.isEmpty {
                Button("Clear All Filters") { libraryViewModel.filters = LibraryFilters() }
            }
        }
        // Checking zero or more filters from a list, same as every multi-select
        // review queue elsewhere — a checkbox, not a settings-style switch. Applied
        // once here rather than per-`Toggle` since it cascades through the
        // environment to every `Toggle` in the Form (the type/tag/rating ones —
        // Printed/Material/Printer/Slicer above are `Picker`s, unaffected).
        .toggleStyle(.checkbox)
        .formStyle(.grouped)
        .frame(width: 300, height: 420)
    }

    private func extensionBinding(_ ext: String) -> Binding<Bool> {
        Binding(
            get: { libraryViewModel.filters.extensions.contains(ext) },
            set: { isOn in
                if isOn { libraryViewModel.filters.extensions.insert(ext) } else { libraryViewModel.filters.extensions.remove(ext) }
            }
        )
    }

    private func tagBinding(_ name: String) -> Binding<Bool> {
        Binding(
            get: { libraryViewModel.filters.tags.contains(name) },
            set: { isOn in
                if isOn { libraryViewModel.filters.tags.insert(name) } else { libraryViewModel.filters.tags.remove(name) }
            }
        )
    }

    private func ratingBinding(_ star: Int) -> Binding<Bool> {
        Binding(
            get: { libraryViewModel.filters.ratings.contains(star) },
            set: { isOn in
                if isOn { libraryViewModel.filters.ratings.insert(star) } else { libraryViewModel.filters.ratings.remove(star) }
            }
        )
    }
}
