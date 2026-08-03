import SpoolCore
import SwiftUI

extension ProjectColor {
    /// SwiftUI can't live in SpoolCore (pure logic module), so the color mapping lives
    /// here instead — every place a project's flag color needs to actually render uses
    /// this same lookup, so the palette can only ever be changed in one place.
    var swiftUIColor: Color {
        switch self {
        case .blue: return .blue
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .purple: return .purple
        case .gray: return .gray
        }
    }
}

/// A row of color swatches — tap one to set a project's flag color. Shared by the
/// project detail toolbar and (if added later) any other color-picking spot, so the
/// palette and layout stay in exactly one place.
struct ProjectColorPicker: View {
    let selected: ProjectColor
    let onSelect: (ProjectColor) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ProjectColor.allCases, id: \.self) { color in
                Button(action: { onSelect(color) }) {
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 18, height: 18)
                        .overlay {
                            if color == selected {
                                Circle().strokeBorder(Color.primary, lineWidth: 2).padding(-2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(color.rawValue.capitalized)
                .accessibilityLabel(color.rawValue.capitalized)
                .accessibilityAddTraits(color == selected ? [.isSelected] : [])
            }
        }
        .padding(8)
    }
}

/// One row in the nestable projects tree — recursive via `DisclosureGroup` for any
/// project that has children, a plain `Label` otherwise. Lives in the same
/// `List(selection:)` as "All Files" in `ContentView`'s sidebar, so tapping a project
/// switches the detail pane the same way tapping "All Files" does.
struct ProjectTreeRow: View {
    let project: Project
    @ObservedObject var viewModel: ProjectsViewModel

    var body: some View {
        let kids = viewModel.children(ofParentId: project.id)
        if kids.isEmpty {
            row
        } else {
            DisclosureGroup {
                ForEach(kids) { child in
                    ProjectTreeRow(project: child, viewModel: viewModel)
                }
            } label: {
                row
            }
        }
    }

    private var row: some View {
        Label {
            Text(project.name)
        } icon: {
            Image(systemName: "folder.fill").foregroundStyle(project.color.swiftUIColor)
        }
        .tag(SidebarSelection.project(project.id ?? -1))
    }
}

/// Prompts for a name and creates a top-level project — the "+" affordance next to the
/// Projects section header, deliberately just an icon rather than a labeled button
/// since its context (right next to the section title) already says what it does.
struct NewProjectButton: View {
    @ObservedObject var viewModel: ProjectsViewModel
    @State private var isPresenting = false
    @State private var name = ""

    var body: some View {
        Button(action: { isPresenting = true; name = "" }) {
            Image(systemName: "plus.circle")
        }
        .buttonStyle(.plain)
        .help("New Project")
        .accessibilityLabel("New Project")
        .alert("New Project", isPresented: $isPresenting) {
            TextField("Project name", text: $name)
            Button("Create") {
                let trimmed = name.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                Task { await viewModel.createProject(name: trimmed) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A project's own "these are my files" page — the cards view the plan calls for,
/// reusing the exact same `FileCardView` the main library grid uses so a project looks
/// like a filtered view of the library, not a different feature.
struct ProjectDetailView: View {
    let projectId: Int64
    /// Drives both the parent/all-projects breadcrumb and sub-project card navigation,
    /// and moves off this project after a successful merge (which deletes it).
    @Binding var selection: SidebarSelection?
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var projectsViewModel: ProjectsViewModel
    @State private var files: [SpoolFile] = []
    @State private var suggestedFiles: [SpoolFile] = []
    @State private var sidecarFiles: [SidecarFile] = []
    @State private var summary: ProjectSummary?
    @State private var childSummaries: [ProjectSummary] = []
    @State private var childVisuals: [Int64: ProjectCardVisuals] = [:]
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showingMerge = false
    @State private var showingMove = false
    @State private var showingColorPicker = false

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]
    private let projectColumns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)]

    private var project: Project? { projectsViewModel.allProjects.first { $0.id == projectId } }
    private var parent: Project? {
        guard let parentId = project?.parentProjectId else { return nil }
        return projectsViewModel.allProjects.first { $0.id == parentId }
    }

    var body: some View {
        Group {
            if files.isEmpty && suggestedFiles.isEmpty && childSummaries.isEmpty && sidecarFiles.isEmpty {
                ContentUnavailableView(
                    "No files in this project yet",
                    systemImage: "folder",
                    description: Text("Add files to this project from their detail page.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !childSummaries.isEmpty {
                            subprojectsSection
                        }
                        if !suggestedFiles.isEmpty {
                            suggestedFilesSection
                        }
                        if !files.isEmpty {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(files) { file in
                                    NavigationLink(destination: FileDetailView(file: file, environment: environment)) {
                                        FileCardView(file: file, thumbnailsDirectory: environment.thumbnailsDirectory)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        if !sidecarFiles.isEmpty {
                            sidecarFilesSection
                        }
                    }
                    .padding()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                breadcrumb
                if let summary { summaryLine(summary) }
            }
            .padding(.horizontal).padding(.top, 8).padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
        .navigationTitle(project?.name ?? "Project")
        .toolbar {
            ToolbarItem {
                Button(action: { showingColorPicker = true }) {
                    Circle().fill(project?.color.swiftUIColor ?? ProjectColor.blue.swiftUIColor).frame(width: 14, height: 14)
                }
                .help("Set a flag color")
                .accessibilityLabel("Set flag color, currently \((project?.color ?? .blue).rawValue.capitalized)")
                .popover(isPresented: $showingColorPicker) {
                    ProjectColorPicker(selected: project?.color ?? .blue) { color in
                        if let project {
                            Task { await projectsViewModel.setColor(project, to: color) }
                        }
                        showingColorPicker = false
                    }
                }
            }
            ToolbarItem {
                Button("Rename", systemImage: "pencil") {
                    renameText = project?.name ?? ""
                    isRenaming = true
                }
                .help("Rename this project")
            }
            ToolbarItem {
                Button("Move to…", systemImage: "folder") { showingMove = true }
                    .help("Make this a sub-project of another, or move it back to the top level")
            }
            ToolbarItem {
                Button("Merge Into…", systemImage: "arrow.triangle.merge") { showingMerge = true }
                    .help("Merge this project's files and sub-projects into another project, then delete it")
            }
        }
        .alert("Rename Project", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if let project, !trimmed.isEmpty {
                    Task { await projectsViewModel.rename(project, to: trimmed) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingMerge) {
            MergeProjectSheet(sourceProjectId: projectId, onMerged: {
                showingMerge = false
                selection = .allProjects
            })
        }
        .sheet(isPresented: $showingMove) {
            MoveProjectSheet(projectId: projectId)
        }
        .task(id: projectId) { await loadAll() }
    }

    /// Walks `parentProjectId` all the way to the root, root first — a project nested
    /// several levels deep used to only expose a single "back one level" button, so
    /// jumping to a grandparent meant clicking back repeatedly and reading each
    /// intermediate name as it flashed by. Every ancestor is its own tappable segment
    /// now, Finder-path-bar style, so any level is reachable in one click.
    private var ancestorChain: [Project] {
        var chain: [Project] = []
        var current = parent
        while let ancestor = current {
            chain.append(ancestor)
            current = projectsViewModel.allProjects.first { $0.id == ancestor.parentProjectId }
        }
        return chain.reversed()
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            breadcrumbSegment("All Projects", systemImage: "square.grid.2x2") { selection = .allProjects }
            ForEach(ancestorChain) { ancestor in
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                breadcrumbSegment(ancestor.name) {
                    selection = ancestor.id.map { SidebarSelection.project($0) } ?? .allProjects
                }
            }
        }
        .font(.callout)
    }

    private func breadcrumbSegment(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private func summaryLine(_ summary: ProjectSummary) -> some View {
        var parts = ["\(summary.fileCount) file\(summary.fileCount == 1 ? "" : "s")"]
        if summary.subprojectCount > 0 {
            parts.append("\(summary.subprojectCount) sub-project\(summary.subprojectCount == 1 ? "" : "s")")
        }
        return Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
    }

    /// Direct sub-projects shown as cards on their parent's own page — the same
    /// `ProjectCardView` the all-projects overview uses, so a project reads as a
    /// browsable tree, not just something you navigate one sidebar click at a time.
    private var subprojectsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sub-projects (\(childSummaries.count))").font(.headline)
            LazyVGrid(columns: projectColumns, spacing: 16) {
                ForEach(childSummaries) { child in
                    Button(action: { selection = .project(child.project.id ?? -1) }) {
                        ProjectCardView(summary: child, visuals: childVisuals[child.project.id ?? -1], thumbnailsDirectory: environment.thumbnailsDirectory)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
        }
    }

    /// Files the folder-grouping heuristic proposed for this project but nobody's
    /// reviewed yet — its own section, tinted like every other suggestion in the app,
    /// so reviewing a match doesn't require navigating to the file's own detail page.
    private var suggestedFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested (\(suggestedFiles.count))").font(.headline).suggestionTint()
            ForEach(suggestedFiles) { file in
                HStack {
                    Text(file.displayName ?? file.filename).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    ConfirmRejectButtons(
                        onConfirm: { Task { await confirmSuggested(file) } },
                        onReject: { Task { await rejectSuggested(file) } }
                    )
                }
            }
            Divider()
        }
    }

    /// Non-model files (READMEs, preview photos, instruction PDFs) sitting alongside
    /// this project's confirmed files — no CAD/slicer app to open them in, so each row
    /// just opens with the system's own default handler for that file type.
    private var sidecarFilesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files in This Folder (\(sidecarFiles.count))").font(.headline)
            ForEach(sidecarFiles) { sidecar in
                Button(action: { OpenInAppService.openWithDefaultApplication(fileURL: URL(fileURLWithPath: sidecar.path)) }) {
                    HStack(spacing: 8) {
                        sidecarThumbnail(sidecar)
                        Text(sidecar.filename).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: sidecar.sizeBytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Open with the default app for this file type")
            }
        }
    }

    @ViewBuilder
    private func sidecarThumbnail(_ sidecar: SidecarFile) -> some View {
        if let path = sidecar.thumbnailPath,
           let image = NSImage(contentsOfFile: environment.thumbnailsDirectory.appendingPathComponent(path).path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24).clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "doc").frame(width: 24, height: 24).foregroundStyle(.secondary)
        }
    }

    private func loadAll() async {
        async let confirmed = environment.projects.confirmedFiles(inProjectId: projectId)
        async let suggested = environment.projects.suggestedFiles(inProjectId: projectId)
        async let summaries = environment.projects.projectSummaries()
        async let sidecarsResult = environment.sidecars.sidecars(inProjectId: projectId)
        files = (try? await confirmed) ?? []
        suggestedFiles = (try? await suggested) ?? []
        sidecarFiles = (try? await sidecarsResult) ?? []
        let allSummaries = (try? await summaries) ?? []
        summary = allSummaries.first { $0.project.id == projectId }
        childSummaries = allSummaries.filter { $0.project.parentProjectId == projectId }
        childVisuals = (try? await environment.projects.projectCardVisuals(forProjectIds: childSummaries.compactMap(\.project.id))) ?? [:]
    }

    private func confirmSuggested(_ file: SpoolFile) async {
        guard let fileId = file.id else { return }
        try? await environment.suggestionReview.confirmProjectMembership(projectId: projectId, fileId: fileId)
        await loadAll()
    }

    private func rejectSuggested(_ file: SpoolFile) async {
        guard let fileId = file.id else { return }
        try? await environment.suggestionReview.rejectProjectMembership(projectId: projectId, fileId: fileId)
        await loadAll()
    }
}

/// Picks a target project and merges the source into it — source's files and
/// sub-projects move to the target, and source itself is deleted with no undo, so this
/// asks for an explicit confirmation click rather than merging the moment a row is
/// tapped.
private struct MergeProjectSheet: View {
    let sourceProjectId: Int64
    let onMerged: () -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var projectsViewModel: ProjectsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var targetProjectId: Int64?
    @State private var isMerging = false

    // Excludes the source itself and anything nested under it — merging into your own
    // descendant would be a cycle (or, once source is deleted, a meaningless no-op).
    private var candidates: [Project] {
        let excluded = projectsViewModel.descendantIds(of: sourceProjectId).union([sourceProjectId])
        return projectsViewModel.allProjects.filter { !excluded.contains($0.id ?? -1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge Into Another Project").font(.headline)
            Text("Every file and sub-project moves into the project you pick below, and this project is then deleted. There's no undo.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates, id: \.id) { project in
                        Button(action: { targetProjectId = project.id }) {
                            SearchResultRow(title: project.name, isSelected: targetProjectId == project.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary).opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Merge", role: .destructive) {
                    guard let targetProjectId else { return }
                    isMerging = true
                    Task {
                        _ = try? await environment.projects.mergeProjects(sourceId: sourceProjectId, intoTargetId: targetProjectId)
                        isMerging = false
                        onMerged()
                    }
                }
                .disabled(targetProjectId == nil || isMerging)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

private enum MoveTarget: Hashable {
    case topLevel
    case project(Int64)
}

/// Reparents a project — a sub-project of another, or back to the top level.
/// Excludes the project itself and anything nested under it (moving into your own
/// descendant would be a cycle), same guard as `MergeProjectSheet`'s picker.
private struct MoveProjectSheet: View {
    let projectId: Int64
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var projectsViewModel: ProjectsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTarget: MoveTarget?
    @State private var isMoving = false

    private var candidates: [Project] {
        let excluded = projectsViewModel.descendantIds(of: projectId).union([projectId])
        return projectsViewModel.allProjects.filter { !excluded.contains($0.id ?? -1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move to Another Project").font(.headline)
            Text("Makes this a sub-project of another, or moves it back to the top level.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    Button(action: { selectedTarget = .topLevel }) {
                        SearchResultRow(title: "Top Level", isSelected: selectedTarget == .topLevel)
                    }
                    .buttonStyle(.plain)
                    ForEach(candidates, id: \.id) { project in
                        Button(action: { selectedTarget = .project(project.id ?? -1) }) {
                            SearchResultRow(title: project.name, isSelected: selectedTarget == .project(project.id ?? -1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary).opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Move") {
                    guard let selectedTarget else { return }
                    guard let project = projectsViewModel.allProjects.first(where: { $0.id == projectId }) else { return }
                    let newParentId: Int64? = { if case .project(let id) = selectedTarget { return id } else { return nil } }()
                    isMoving = true
                    Task {
                        await projectsViewModel.reparent(project, toParentId: newParentId)
                        isMoving = false
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTarget == nil || isMoving)
            }
        }
        .padding()
        .frame(width: 420)
    }
}

private enum ProjectsViewMode: String {
    case grid, list
}

/// The top-level "browse every project" page — a flat grid of project cards (thumbnail
/// collage, name, extension badges, file/sub-project counts), the counterpart to the
/// sidebar's nested tree for when you want to scan/search across all projects at once
/// rather than drill down.
struct ProjectsOverviewView: View {
    @Binding var selection: SidebarSelection?
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var projectsViewModel: ProjectsViewModel
    @State private var summaries: [ProjectSummary] = []
    @State private var visuals: [Int64: ProjectCardVisuals] = [:]
    @State private var cleanupCount = 0
    @State private var showingCleanup = false
    // Same key convention as LibraryGridView's `libraryViewMode` — a separate key since
    // this is an independent toggle over a different collection (projects, not files).
    @AppStorage("projectsViewMode") private var viewModeRaw = ProjectsViewMode.grid.rawValue

    private var viewMode: ProjectsViewMode { ProjectsViewMode(rawValue: viewModeRaw) ?? .grid }
    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)]

    var body: some View {
        Group {
            if summaries.isEmpty {
                ContentUnavailableView(
                    "No projects yet",
                    systemImage: "square.grid.2x2",
                    description: Text("Create one from any file's detail page, or with the + button in the sidebar.")
                )
            } else if viewMode == .grid {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(summaries) { summary in
                            Button(action: { selection = .project(summary.project.id ?? -1) }) {
                                ProjectCardView(
                                    summary: summary,
                                    visuals: visuals[summary.project.id ?? -1],
                                    thumbnailsDirectory: environment.thumbnailsDirectory
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            } else {
                List(summaries) { summary in
                    Button(action: { selection = .project(summary.project.id ?? -1) }) {
                        ProjectListRow(
                            summary: summary,
                            visuals: visuals[summary.project.id ?? -1],
                            thumbnailsDirectory: environment.thumbnailsDirectory
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $viewModeRaw) {
                    Image(systemName: "square.grid.2x2").tag(ProjectsViewMode.grid.rawValue).accessibilityLabel("Grid view")
                    Image(systemName: "list.bullet").tag(ProjectsViewMode.list.rawValue).accessibilityLabel("List view")
                }
                .pickerStyle(.segmented)
                .help("Switch between grid and list view")
            }
            ToolbarItem {
                Button {
                    showingCleanup = true
                } label: {
                    Label(
                        cleanupCount > 0 ? "Clean Up Names (\(cleanupCount))…" : "Clean Up Names…",
                        systemImage: "wand.and.stars"
                    )
                }
                .help("Review suggested cleanups for messy, folder-derived project names")
            }
        }
        .sheet(isPresented: $showingCleanup, onDismiss: { Task { await load() } }) {
            ProjectCleanupSheet()
        }
        .task { await load() }
    }

    private func load() async {
        await projectsViewModel.load()
        do {
            let summaries = try await environment.projects.projectSummaries()
            self.summaries = summaries
            visuals = try await environment.projects.projectCardVisuals(forProjectIds: summaries.compactMap(\.project.id))
            cleanupCount = try await environment.projects.projectsNeedingNameCleanup().count
        } catch {
            summaries = []
        }
    }
}

private struct ProjectCardView: View {
    let summary: ProjectSummary
    let visuals: ProjectCardVisuals?
    let thumbnailsDirectory: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                // Same `Color.clear` sizing scaffold as `ProjectSearchResultCard` in
                // LibraryGridView — `ProjectThumbnailCollage` reports a different
                // intrinsic size depending on whether it's showing the empty-folder
                // state, one image, or a 2x2 grid, and applying `aspectRatio(1, .fit)`
                // directly to it (as this used to) let that leak into the box size,
                // making cards in the same grid different sizes from each other.
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ProjectThumbnailCollage(
                            paths: visuals?.thumbnailPaths ?? [], thumbnailsDirectory: thumbnailsDirectory, fileCount: summary.fileCount
                        )
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("PROJECT")
                    .font(.caption2).bold()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(summary.project.color.swiftUIColor.opacity(0.85)))
                    .foregroundStyle(.white)
                    .padding(6)
            }
            Text(summary.project.name).font(.caption).lineLimit(1).truncationMode(.middle)
            extensionBadgesRow
            Text(countLabel).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // Always reserves one row's height, whether or not a project has any extension
    // badges — otherwise a project with badges and one without end up different total
    // card heights, and a grid row mixing the two looks ragged. Capped to 4 badges so
    // a project with many file types doesn't grow noticeably wider than its neighbors.
    private var extensionBadgesRow: some View {
        HStack(spacing: 4) {
            let extensions = visuals?.extensions ?? []
            if extensions.isEmpty {
                Text(" ").font(.caption2)
            } else {
                ForEach(extensions.prefix(4), id: \.self) { ext in
                    Text(ext)
                        .font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(.tertiary))
                }
            }
        }
        .frame(height: 16, alignment: .leading)
    }

    private var countLabel: String {
        var parts = ["\(summary.fileCount) file\(summary.fileCount == 1 ? "" : "s")"]
        if summary.subprojectCount > 0 {
            parts.append("\(summary.subprojectCount) sub-project\(summary.subprojectCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ProjectListRow: View {
    let summary: ProjectSummary
    let visuals: ProjectCardVisuals?
    let thumbnailsDirectory: URL

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ProjectThumbnailCollage(
                        paths: visuals?.thumbnailPaths ?? [], thumbnailsDirectory: thumbnailsDirectory, fileCount: summary.fileCount
                    )
                }
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.project.name).lineLimit(1)
                Text(countLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Circle().fill(summary.project.color.swiftUIColor).frame(width: 10, height: 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var countLabel: String {
        var parts = ["\(summary.fileCount) file\(summary.fileCount == 1 ? "" : "s")"]
        if summary.subprojectCount > 0 {
            parts.append("\(summary.subprojectCount) sub-project\(summary.subprojectCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ProjectThumbnailCollage: View {
    let paths: [String]
    let thumbnailsDirectory: URL
    let fileCount: Int

    var body: some View {
        Group {
            if paths.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("\(fileCount) file\(fileCount == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
                }
            } else if paths.count == 1 {
                thumbImage(paths[0])
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)], spacing: 2) {
                    ForEach(paths.prefix(4), id: \.self) { path in
                        thumbImage(path).aspectRatio(1, contentMode: .fill).clipped()
                    }
                }
                .padding(4)
            }
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

/// Review queue for `ProjectService.projectsNeedingNameCleanup()` — per-row apply plus
/// an "Apply All" bulk action, both routed through the same collision-safe rename path
/// so two suggestions that clean up to the identical name never collide.
private struct ProjectCleanupSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [ProjectRenameSuggestion] = []
    @State private var editedNames: [Int64: String] = [:]
    @State private var checkedIds: Set<Int64> = []
    @State private var isLoading = true

    private var allChecked: Bool {
        !suggestions.isEmpty && checkedIds.count == suggestions.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if suggestions.isEmpty {
                    ContentUnavailableView(
                        "Nothing to clean up", systemImage: "checkmark.circle",
                        description: Text("Every project name already looks clean.")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Edit any suggestion before applying, or uncheck rows you don't want changed.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal).padding(.top, 8)
                        Toggle("Select all", isOn: Binding(
                            get: { allChecked },
                            set: { checkedIds = $0 ? Set(suggestions.compactMap(\.id)) : [] }
                        ))
                        .padding(.horizontal).padding(.vertical, 6)
                        List {
                            ForEach(suggestions, id: \.id) { suggestion in
                                CleanupSuggestionRow(
                                    suggestion: suggestion,
                                    isChecked: Binding(
                                        get: { suggestion.id.map { checkedIds.contains($0) } ?? false },
                                        set: { checked in
                                            guard let id = suggestion.id else { return }
                                            if checked { checkedIds.insert(id) } else { checkedIds.remove(id) }
                                        }
                                    ),
                                    editedName: nameBinding(for: suggestion),
                                    onApply: { Task { await applyOne(suggestion) } }
                                )
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Apply Selected (\(checkedIds.count))") { Task { await applySelected() } }
                                .disabled(checkedIds.isEmpty)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Clean Up Project Names")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply All (\(suggestions.count))") { Task { await applyAll() } }
                        .disabled(suggestions.isEmpty)
                        .help("Applies every suggestion exactly as suggested, ignoring any edits above")
                }
            }
            .task { await load() }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private func nameBinding(for suggestion: ProjectRenameSuggestion) -> Binding<String> {
        Binding(
            get: { suggestion.id.flatMap { editedNames[$0] } ?? suggestion.suggestedName },
            set: { newValue in
                guard let id = suggestion.id else { return }
                editedNames[id] = newValue
            }
        )
    }

    private func load() async {
        isLoading = true
        suggestions = (try? await environment.projects.projectsNeedingNameCleanup()) ?? []
        editedNames = [:]
        checkedIds = []
        isLoading = false
    }

    private func applyOne(_ suggestion: ProjectRenameSuggestion) async {
        guard let id = suggestion.id else { return }
        let name = editedNames[id] ?? suggestion.suggestedName
        try? await environment.projects.renameProjectsBulk([(projectId: id, newName: name)])
        await load()
    }

    private func applySelected() async {
        let renames = suggestions.compactMap { suggestion -> (projectId: Int64, newName: String)? in
            guard let id = suggestion.id, checkedIds.contains(id) else { return nil }
            return (id, editedNames[id] ?? suggestion.suggestedName)
        }
        try? await environment.projects.renameProjectsBulk(renames)
        await load()
    }

    private func applyAll() async {
        _ = try? await environment.projects.renameAllNeedingCleanup()
        await load()
    }
}

private struct CleanupSuggestionRow: View {
    let suggestion: ProjectRenameSuggestion
    @Binding var isChecked: Bool
    @Binding var editedName: String
    let onApply: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Toggle("", isOn: $isChecked).labelsHidden()
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.project.name)
                    .font(.caption).foregroundStyle(.secondary).strikethrough()
                TextField("New name", text: $editedName)
                    .textFieldStyle(.roundedBorder)
            }
            Button("Apply", action: onApply)
        }
        .padding(.vertical, 4)
    }
}
