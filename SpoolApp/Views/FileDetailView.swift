import AppKit
import SpoolCore
import SwiftUI
import UniformTypeIdentifiers

struct FileDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: FileDetailViewModel
    @Environment(\.undoManager) private var undoManager
    /// Switches the main sidebar to a project (clicking a project pill) — same
    /// "reset the pushed nav path, then change selection" shape as `ContentView`'s own
    /// project-card navigation, just reachable from wherever this file detail page was
    /// pushed from (the library grid or a project's own file grid).
    let onNavigate: (SidebarSelection) -> Void
    /// Jumps to All Files with this tag's name already in the search field (clicking a
    /// tag pill) — a plain text search, not the structured tag filter, matching "a
    /// search for that tag" as asked for; also matches filenames/other metadata
    /// containing the same text, which is an acceptable, simpler tradeoff than
    /// threading a whole separate filter-state channel through for one click target.
    let onSearchForTag: (String) -> Void
    @State private var newTagText = ""
    @State private var showingAddTag = false
    @State private var newProjectName = ""
    @State private var showingNewProjectField = false
    @State private var showingAddRelationship = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showingPhotoUpload = false
    @FocusState private var isAddTagFocused: Bool
    @FocusState private var isPrintLogCommentsFocused: Bool
    @FocusState private var isRenameFieldFocused: Bool

    init(
        file: SpoolFile, environment: AppEnvironment,
        onNavigate: @escaping (SidebarSelection) -> Void, onSearchForTag: @escaping (String) -> Void
    ) {
        _viewModel = StateObject(wrappedValue: FileDetailViewModel(file: file, environment: environment))
        self.onNavigate = onNavigate
        self.onSearchForTag = onSearchForTag
    }

    /// Runs `forward` immediately, and registers `backward` as the system Undo action
    /// (⌘Z) — tags, project membership, rename, and relationships are all cheap,
    /// fully-reversible edits that had no undo support at all before this. Each undo
    /// re-registers the opposite direction as the next undo action, so redo (⇧⌘Z) keeps
    /// working indefinitely rather than being a one-shot.
    private func performAndRegisterUndo(actionName: String, forward: @escaping () async -> Void, backward: @escaping () async -> Void) {
        Task { await forward() }
        registerUndo(actionName: actionName, action: backward, inverse: forward)
    }

    private func registerUndo(actionName: String, action: @escaping () async -> Void, inverse: @escaping () async -> Void) {
        undoManager?.registerUndo(withTarget: viewModel) { [self] _ in
            Task { await action() }
            registerUndo(actionName: actionName, action: inverse, inverse: action)
        }
        undoManager?.setActionName(actionName)
    }

    private func addTagAndRegisterUndo(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        performAndRegisterUndo(
            actionName: "Add Tag",
            forward: { await viewModel.addTag(name) },
            backward: {
                if let tag = viewModel.tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                    await viewModel.removeTag(tag)
                }
            }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                // Two columns once there's room for them — tags/projects/relationships
                // on the left, print metadata/log on the right, rather than one long
                // vertical stack that leaves most of a wide window empty.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 32) {
                        VStack(alignment: .leading, spacing: 20) {
                            tagsSection
                            projectsSection
                            relationshipsSection
                        }
                        .frame(width: 360, alignment: .leading)
                        VStack(alignment: .leading, spacing: 20) {
                            printMetadataSection
                            printLogSection
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        tagsSection
                        projectsSection
                        printMetadataSection
                        printLogSection
                        relationshipsSection
                    }
                }
                footer
            }
            .padding()
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(viewModel.file.displayName ?? viewModel.file.filename)
        .task { await viewModel.load() }
        // See SettingsView's identical fix — `.constant()` here is a real, confirmed
        // trigger for "Publishing changes from within view updates is not allowed".
        .alert("Error", isPresented: Binding(
            get: { viewModel.lastError != nil },
            set: { if !$0 { viewModel.lastError = nil } }
        ), actions: {
            Button("OK") { viewModel.lastError = nil }
        }, message: { Text(viewModel.lastError ?? "") })
        // The very top-right of the window, not an in-content row — these are the
        // file's own "do something with it elsewhere" actions (open in a CAD/slicer
        // app, reveal on disk, share), the same real-toolbar treatment
        // ProjectDetailView already gives its own page-level actions.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ForEach(viewModel.detectedApps) { app in
                    Button(action: { viewModel.openInApp(app) }) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    .help("Open in \(app.name)")
                    .accessibilityLabel("Open in \(app.name)")
                }
                Button(action: { OpenInAppService.revealInFinder(fileURL: URL(fileURLWithPath: viewModel.file.path)) }) {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
                ShareLink(item: URL(fileURLWithPath: viewModel.file.path)) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share this file")
            }
        }
        .sheet(isPresented: $showingPhotoUpload) {
            PhotoUploadSheet(onUpload: { url in Task { await viewModel.uploadPhoto(from: url) } })
        }
    }

    private func startRenaming() {
        renameText = viewModel.file.displayName ?? viewModel.file.filename
        isRenaming = true
        isRenameFieldFocused = true
    }

    /// Commits the in-place rename field — Enter (`.onSubmit`) or simply clicking
    /// away (the `.onChange(of: isRenameFieldFocused)` below) both land here, so
    /// `isRenaming` is flipped off first to make a second call from the other path a
    /// no-op rather than double-committing. Escape cancels via `.onExitCommand`
    /// instead, which never calls this.
    private func commitRename() {
        guard isRenaming else { return }
        isRenaming = false
        let previousName = viewModel.file.displayName ?? viewModel.file.filename
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != previousName else { return }
        performAndRegisterUndo(
            actionName: "Rename",
            forward: { await viewModel.rename(to: newName) },
            backward: { await viewModel.rename(to: previousName) }
        )
    }

    private var projectMembershipSummary: String {
        let names = viewModel.confirmedProjects.map(\.name)
        if names.count == 1 { return names[0] }
        return names.joined(separator: ", ")
    }

    /// "Use as thumbnail" is a cheap, fully-reversible switch — same undo treatment as
    /// rename/tags/relationships. `backward` re-activates whichever slide was active
    /// before this click, or does nothing if none was (a file with no render yet and
    /// no prior photo).
    private func useAsThumbnailAndRegisterUndo(_ image: FileGalleryImage) {
        let previous = viewModel.activeGalleryImage
        performAndRegisterUndo(
            actionName: "Use as Thumbnail",
            forward: { await viewModel.useAsThumbnail(image) },
            backward: {
                if let previous { await viewModel.useAsThumbnail(previous) }
            }
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            FileGalleryCarousel(
                images: viewModel.galleryImages,
                activeImageId: viewModel.file.activeGalleryImageId,
                renderStatus: viewModel.file.renderStatus,
                ext: viewModel.file.ext,
                thumbnailsDirectory: environment.thumbnailsDirectory,
                onUseAsThumbnail: useAsThumbnailAndRegisterUndo,
                onDelete: { image in Task { await viewModel.deleteGalleryImage(image) } },
                onUpload: { showingPhotoUpload = true }
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    // In-place, not a pop-up alert — click the pencil (or the name
                    // itself), the title becomes an editable field right where it
                    // already was, Finder/Xcode-style. Enter or clicking away saves;
                    // Escape (`.onExitCommand`) discards without asking.
                    if isRenaming {
                        TextField("Name", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(.title2).bold()
                            .focused($isRenameFieldFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { isRenaming = false }
                            .onChange(of: isRenameFieldFocused) { _, focused in
                                if !focused { commitRename() }
                            }
                    } else {
                        Text(viewModel.file.displayName ?? viewModel.file.filename).font(.title2).bold()
                        // A real Button, not a bare `.onTapGesture` on the Text above —
                        // see the identical reasoning on the star-rating buttons below.
                        Button(action: startRenaming) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                        .help("Rename (only how it's shown in Spool — the file on disk is never touched)")
                        .accessibilityLabel("Rename")
                    }
                }
                Text(viewModel.file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !viewModel.confirmedProjects.isEmpty {
                    // Glanceable the moment the page opens — the full "Projects"
                    // section further down (with add/remove/suggestions) is the same
                    // data, but clicking into a file from a project's own page
                    // shouldn't require scrolling just to confirm which project(s)
                    // it's actually in.
                    Label(projectMembershipSummary, systemImage: "folder.fill")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let x = viewModel.file.bboxX, let y = viewModel.file.bboxY, let z = viewModel.file.bboxZ {
                    Text(String(format: "%.1f × %.1f × %.1f mm", x, y, z)).font(.callout)
                }
                if viewModel.file.isManifold == false {
                    Label("Not watertight", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                }
                if viewModel.file.renderStatus == .failed {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(RenderErrorLabel.label(for: viewModel.file.renderError), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        Text(renderFailureExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .help(viewModel.file.renderError ?? "")
                }
                // Moved up from its own "Printed" section further down the page — a
                // status this glanceable (and this cheap to flip) belongs with the
                // rest of the header's at-a-glance facts, not buried a scroll away.
                // Still a real Toggle underneath (see its own comment on
                // `printLogSection` for why), just relocated.
                Toggle(isOn: $viewModel.printedInput) {
                    Label(
                        viewModel.printedInput ? "Printed" : "Mark as Printed",
                        systemImage: viewModel.printedInput ? "checkmark.seal.fill" : "seal"
                    )
                }
                .toggleStyle(.button)
                .tint(.green)
                .controlSize(.small)
            }
            Spacer()
        }
    }

    /// Distinguishes the two mesh-safety guards deliberately rejecting a file (working
    /// as designed — the guard exists specifically to avoid the OOM crash loops a real
    /// attempt to render these would cause) from a genuine, unexpected failure, which
    /// the generic "Render failed" label alone didn't make clear either way.
    private var renderFailureExplanation: String {
        switch RenderErrorLabel.category(for: viewModel.file.renderError) {
        case .knownLimit:
            return "This is a known limit, not a bug — the file is safely skipped rather than risking a crash."
        case .unexpected:
            if let error = viewModel.file.renderError, !error.isEmpty {
                return "This wasn't expected. Details: \(error)"
            }
            return "This wasn't expected, and no further detail was recorded."
        }
    }

    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Tags").font(.headline)
                Spacer()
                Button(action: {
                    showingAddTag = true
                    isAddTagFocused = true
                }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Same fixed box as Projects' Menu-based "+" and Related Files'
                // Button-based "+" — a `Menu` and a plain `Button` don't share the
                // same default padding/hit-target even with identical icon content,
                // so without this their "+"s land at very slightly different
                // vertical positions despite looking like the same control.
                .frame(width: 20, height: 20)
                .help("Add a tag")
                .accessibilityLabel("Add a tag")
            }
            FlowChips(items: viewModel.tags, label: { $0.name }, onRemove: { tag in
                performAndRegisterUndo(
                    actionName: "Remove Tag",
                    forward: { await viewModel.removeTag(tag) },
                    backward: { await viewModel.addTag(tag.name) }
                )
            }, onTap: { tag in onSearchForTag(tag.name) })
            if showingAddTag {
                HStack {
                    TextField("Add tag…", text: $newTagText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .focused($isAddTagFocused)
                        .onSubmit {
                            addTagAndRegisterUndo(newTagText)
                            newTagText = ""
                            showingAddTag = false
                        }
                    Button("Add") {
                        addTagAndRegisterUndo(newTagText)
                        newTagText = ""
                        showingAddTag = false
                    }
                    .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { showingAddTag = false; newTagText = "" }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Projects").font(.headline)
                Spacer()
                Menu {
                    ForEach(viewModel.allProjects) { project in
                        Button(project.name) {
                            performAndRegisterUndo(
                                actionName: "Add to Project",
                                forward: { await viewModel.addToProject(project) },
                                backward: { await viewModel.removeFromProject(project) }
                            )
                        }
                    }
                    Divider()
                    Button("Create New…") { showingNewProjectField = true }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .foregroundStyle(.secondary)
                // Without this, a `Menu`'s default disclosure chevron sits next to
                // the icon, throwing this "+" out of alignment with Tags' and
                // Related Files' plain-`Button` "+" right above and below it —
                // clicking still opens the same dropdown either way.
                .menuIndicator(.hidden)
                .fixedSize()
                // See Tags' identical note — a `Menu` and a `Button` don't share the
                // same default padding even with identical icon content.
                .frame(width: 20, height: 20)
                .help("Add to a project")
                .accessibilityLabel("Add to a project")
            }
            FlowChips(items: viewModel.confirmedProjects, label: { $0.name }, onRemove: { project in
                performAndRegisterUndo(
                    actionName: "Remove from Project",
                    forward: { await viewModel.removeFromProject(project) },
                    backward: { await viewModel.addToProject(project) }
                )
            }, onTap: { project in onNavigate(.project(project.id ?? -1)) })

            if !viewModel.suggestedProjects.isEmpty {
                Text("Suggested").font(.caption).foregroundStyle(.secondary)
                ForEach(viewModel.suggestedProjects) { project in
                    HStack {
                        Text(project.name).suggestionTint()
                        Spacer()
                        ConfirmRejectButtons(
                            onConfirm: { Task { await viewModel.confirmProject(project) } },
                            onReject: { Task { await viewModel.rejectProject(project) } }
                        )
                    }
                }
            }

            if showingNewProjectField {
                HStack {
                    TextField("New project name", text: $newProjectName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .onSubmit {
                            Task {
                                await viewModel.createAndAddToNewProject(name: newProjectName)
                                newProjectName = ""
                                showingNewProjectField = false
                            }
                        }
                    Button("Cancel") { showingNewProjectField = false; newProjectName = "" }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var printMetadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Print Metadata").font(.headline)
            if let source = viewModel.printMetadata?.source, source != .manual {
                Text(source == .autoExtracted3MF ? "Auto-extracted from the 3MF project file" : "Auto-extracted from the gcode footer")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading) {
                GridRow {
                    Text("Material").foregroundStyle(.secondary)
                    TextField("", text: $viewModel.materialInput).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Printer").foregroundStyle(.secondary)
                    TextField("", text: $viewModel.printerProfileInput).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Slicer").foregroundStyle(.secondary)
                    TextField("", text: $viewModel.slicerInput).textFieldStyle(.roundedBorder)
                }
            }
            TextField("Notes", text: $viewModel.notesInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            if let settings = viewModel.printMetadata?.settingsJson?.value {
                structuredSettingsSummary(settings)
            }
            HStack {
                Spacer()
                Button("Save") { Task { await viewModel.saveMetadataForm() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
    }

    private func structuredSettingsSummary(_ settings: PrintSettings) -> some View {
        var parts: [String] = []
        if let nozzle = settings.nozzleDiameterMM { parts.append(String(format: "%.2fmm nozzle", nozzle)) }
        if let layer = settings.layerHeightMM { parts.append(String(format: "%.2fmm layer height", layer)) }
        if let infill = settings.infillPercent { parts.append(String(format: "%.0f%% infill", infill)) }
        if let grams = settings.filamentUsedGrams { parts.append(String(format: "%.1fg filament", grams)) }
        if let minutes = settings.estimatedPrintMinutes { parts.append(String(format: "%.0f min", minutes)) }
        return Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
    }

    /// No heading — the "Mark as Printed" toggle that used to introduce this section
    /// moved up into the header (a status this glanceable belongs with the file's
    /// other at-a-glance facts, not a scroll away); this is just what shows up
    /// underneath once that's switched on.
    private var printLogSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.printedInput {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ForEach(1...5, id: \.self) { star in
                            // A real Button, not a bare `.onTapGesture` — a tap gesture
                            // on its own is invisible to VoiceOver and unreachable by
                            // keyboard, so this control was previously unusable
                            // without a mouse.
                            Button(action: { viewModel.ratingInput = star }) {
                                Image(systemName: star <= viewModel.ratingInput ? "star.fill" : "star")
                                    .foregroundStyle(.yellow)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(star) star\(star == 1 ? "" : "s")")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Rating")
                    .accessibilityValue("\(viewModel.ratingInput) of 5 stars")
                    TextField("Notes on how it turned out", text: $viewModel.commentsInput, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                        .focused($isPrintLogCommentsFocused)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
            // Only while there's something to save — was always visible before, so
            // it sat there whether or not the checkbox (or rating/notes) had actually
            // changed from what's already saved.
            if viewModel.hasUnsavedPrintLogChanges {
                HStack {
                    Spacer()
                    Button("Save") {
                        isPrintLogCommentsFocused = false
                        Task { await viewModel.savePrintLog() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    private var relationshipsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Related Files").font(.headline)
                Spacer()
                Button(action: { showingAddRelationship = true }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // See Tags' identical note.
                .frame(width: 20, height: 20)
                .help("Add a relationship to another file")
                .accessibilityLabel("Add a relationship to another file")
            }
            ForEach(viewModel.confirmedRelationships, id: \.relationship.id) { pair in
                HStack {
                    Text("\(pair.relationship.type.rawValue.replacingOccurrences(of: "_", with: " ")): \(pair.otherFile.displayName ?? pair.otherFile.filename)")
                    Spacer()
                    Button(action: { removeRelationshipAndRegisterUndo(pair.relationship, otherFileId: pair.otherFile.id) }) {
                        // Outline, not filled — matches the outline `plus.circle` used
                        // by every "add" button on this page, so add/remove read as
                        // one consistent icon pair rather than two different weights.
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove this relationship")
                    .accessibilityLabel("Remove relationship to \(pair.otherFile.displayName ?? pair.otherFile.filename)")
                }
            }
            if !viewModel.suggestedRelationships.isEmpty {
                Text("Suggested").font(.caption).foregroundStyle(.secondary)
                ForEach(viewModel.suggestedRelationships, id: \.relationship.id) { pair in
                    HStack {
                        Text("\(pair.relationship.type.rawValue.replacingOccurrences(of: "_", with: " ")): \(pair.otherFile.displayName ?? pair.otherFile.filename)")
                            .suggestionTint()
                        Spacer()
                        ConfirmRejectButtons(
                            onConfirm: { Task { await viewModel.confirmRelationship(pair.relationship) } },
                            onReject: { Task { await viewModel.rejectRelationship(pair.relationship) } }
                        )
                    }
                }
            }
            if viewModel.confirmedRelationships.isEmpty && viewModel.suggestedRelationships.isEmpty {
                Text("No related files").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingAddRelationship) {
            AddRelationshipSheet(viewModel: viewModel, onAdd: { otherFileId, type in
                addRelationshipAndRegisterUndo(toFileId: otherFileId, type: type)
            })
        }
    }

    /// Recreating the relationship on undo only makes sense in the direction this file
    /// was the "from" side of — the manual add-relationship sheet always creates it
    /// that way, but a suggestion confirmed from the *other* file's page could leave
    /// this file as the "to" side, where blindly re-adding would flip the direction.
    private func removeRelationshipAndRegisterUndo(_ relationship: Relationship, otherFileId: Int64?) {
        guard relationship.fromFileId == viewModel.file.id, let otherFileId else {
            Task { await viewModel.removeRelationship(relationship) }
            return
        }
        performAndRegisterUndo(
            actionName: "Remove Relationship",
            forward: { await viewModel.removeRelationship(relationship) },
            backward: { await viewModel.addRelationship(toFileId: otherFileId, type: relationship.type) }
        )
    }

    private func addRelationshipAndRegisterUndo(toFileId otherFileId: Int64, type: RelationshipType) {
        performAndRegisterUndo(
            actionName: "Add Relationship",
            forward: { await viewModel.addRelationship(toFileId: otherFileId, type: type) },
            backward: {
                if let match = viewModel.confirmedRelationships.first(where: { $0.otherFile.id == otherFileId && $0.relationship.type == type }) {
                    await viewModel.removeRelationship(match.relationship)
                }
            }
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 20) {
                footerItem("Status", viewModel.file.renderStatus.rawValue.capitalized)
                footerItem("Manifold", viewModel.file.isManifold.map { $0 ? "Yes" : "No" } ?? "Unknown")
                if let hash = viewModel.file.contentHash {
                    footerItem("Hash", "\(hash.prefix(12))…")
                }
                footerItem("First seen", viewModel.file.firstSeenAt.formatted(date: .abbreviated, time: .omitted))
                Spacer()
            }
        }
    }

    private func footerItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text("\(label):").foregroundStyle(.secondary)
            Text(value)
        }
        .font(.caption2)
    }
}

/// Manual "add relationship" flow: search for another file, pick a relationship type,
/// and create it directly as confirmed — the counterpart to the auto-suggested
/// relationships above, for links the heuristics won't catch on their own.
private struct AddRelationshipSheet: View {
    @ObservedObject var viewModel: FileDetailViewModel
    /// Routes the actual creation back through `FileDetailView`, rather than calling
    /// `viewModel.addRelationship` directly, so that action can be registered on the
    /// system Undo stack the same way every other edit on the page is.
    let onAdd: (_ otherFileId: Int64, _ type: RelationshipType) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [SpoolFile] = []
    @State private var selectedFileId: Int64?
    @State private var relationshipType: RelationshipType = .variantOf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Relationship").font(.headline)
            TextField("Search files…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .onChange(of: searchText) { _, newValue in
                    Task { results = await viewModel.searchFiles(query: newValue) }
                }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results, id: \.id) { file in
                        Button(action: { selectedFileId = file.id }) {
                            SearchResultRow(title: file.displayName ?? file.filename, isSelected: selectedFileId == file.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary).opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            Picker("Relationship", selection: $relationshipType) {
                Text("Variant of").tag(RelationshipType.variantOf)
                Text("Derived from").tag(RelationshipType.derivedFrom)
                Text("New version of").tag(RelationshipType.newVersionOf)
                Text("Duplicate of").tag(RelationshipType.duplicateOf)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if let selectedFileId {
                        onAdd(selectedFileId, relationshipType)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFileId == nil)
            }
        }
        .padding()
        .frame(width: 440)
        .task { results = await viewModel.searchFiles(query: "") }
    }
}

/// A plain "title + selection checkmark" row, shared by every simple search-and-pick
/// list in the app (add-relationship's file search, merge-project's target picker).
struct SearchResultRow: View {
    let title: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Text(title).lineLimit(1)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
    }
}

/// A simple wrap-layout of removable chips — used for both tags and confirmed
/// projects, which share the exact same "name + x-to-remove" shape.
private struct FlowChips<Item: Identifiable>: View {
    let items: [Item]
    let label: (Item) -> String
    let onRemove: (Item) -> Void
    /// Optional — a chip's name becomes its own `Button` (a sibling of the remove-x,
    /// not nested inside it; SwiftUI doesn't hit-test a `Button` inside another
    /// `Button` reliably) when provided. `nil` keeps a chip's name as plain text, for
    /// any future reuse of this component where tapping the name shouldn't navigate.
    var onTap: ((Item) -> Void)?

    var body: some View {
        if items.isEmpty {
            Text("None").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack {
                ForEach(items) { item in
                    HStack(spacing: 4) {
                        if let onTap {
                            Button(action: { onTap(item) }) {
                                Text(label(item)).font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Open \(label(item))")
                        } else {
                            Text(label(item)).font(.caption)
                        }
                        Button(action: { onRemove(item) }) {
                            // Outline, matching every other remove-x on this page —
                            // see the identical note on Related Files' own xmark.
                            Image(systemName: "xmark.circle").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove \(label(item))")
                        .accessibilityLabel("Remove \(label(item))")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.quaternary))
                }
            }
        }
    }
}

/// The file detail page's thumbnail gallery — a rendered mesh thumbnail plus any
/// designer-photo/uploaded slides, one active at a time. Design ported from a mockup
/// the source app posted for feedback (GitHub issue #9 there) but never actually
/// built; see `FileGalleryService`'s own doc comment for the full story.
///
/// Paging through slides (`selectedIndex`) is separate, local-only UI state from which
/// slide is actually *active* (`activeImageId`, shown everywhere else in the app) —
/// looking at a slide shouldn't itself change the file's thumbnail; only an explicit
/// "Use as thumbnail" click does that.
private struct FileGalleryCarousel: View {
    let images: [FileGalleryImage]
    let activeImageId: Int64?
    let renderStatus: FileRenderStatus
    let ext: String
    let thumbnailsDirectory: URL
    let onUseAsThumbnail: (FileGalleryImage) -> Void
    let onDelete: (FileGalleryImage) -> Void
    let onUpload: () -> Void

    @State private var selectedIndex = 0
    private static let size: CGFloat = 160

    private var currentImage: FileGalleryImage? {
        guard images.indices.contains(selectedIndex) else { return nil }
        return images[selectedIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .top) {
                thumbnail
                    .frame(width: Self.size, height: Self.size)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if images.count > 1 {
                    HStack {
                        pagingButton(systemImage: "chevron.left", label: "Previous photo", isEnabled: selectedIndex > 0, action: previous)
                        Spacer()
                        pagingButton(
                            systemImage: "chevron.right", label: "Next photo", isEnabled: selectedIndex < images.count - 1, action: next
                        )
                    }
                    .padding(.horizontal, 4)
                    .frame(width: Self.size, height: Self.size)
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(selectedIndex + 1) of \(images.count)")
                                .font(.caption2).bold()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(.black.opacity(0.55)))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .padding(6)
                    .frame(width: Self.size, height: Self.size)
                }
            }
            if let currentImage {
                Text(slideLabel(currentImage))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 8) {
                    if currentImage.id == activeImageId {
                        Label("Using this", systemImage: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(.green)
                    } else {
                        Button("Use as thumbnail") { onUseAsThumbnail(currentImage) }
                            .buttonStyle(.link).font(.caption2)
                    }
                    if currentImage.kind != .rendered {
                        Button("Remove", role: .destructive) { onDelete(currentImage) }
                            .buttonStyle(.link).font(.caption2)
                    }
                }
            }
            Button("+ Upload a photo", action: onUpload)
                .buttonStyle(.link).font(.caption2)
        }
        .frame(width: Self.size, alignment: .leading)
        .onAppear { selectActiveOrFirst() }
        .onChange(of: activeImageId) { _, _ in selectActiveOrFirst() }
        .onChange(of: images.count) { _, _ in
            if !images.indices.contains(selectedIndex) { selectedIndex = max(0, images.count - 1) }
        }
    }

    private func selectActiveOrFirst() {
        selectedIndex = images.firstIndex(where: { $0.id == activeImageId }) ?? 0
    }

    private func previous() { selectedIndex = max(0, selectedIndex - 1) }
    private func next() { selectedIndex = min(images.count - 1, selectedIndex + 1) }

    private func pagingButton(systemImage: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.callout).bold()
                .foregroundStyle(.white)
                .padding(6)
                .background(Circle().fill(.black.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0)
        .disabled(!isEnabled)
        .help(label)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let currentImage, let image = NSImage(contentsOfFile: thumbnailsDirectory.appendingPathComponent(currentImage.thumbnailPath).path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8)
        } else {
            // Identical fallback to the pre-gallery single-thumbnail view — a file
            // with no render yet (or none possible) and no photo match shows the same
            // pending/failed/unsupported iconography it always did.
            VStack(spacing: 8) {
                RenderStatusIcon(status: renderStatus, size: 40)
                Text(ext.uppercased()).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func slideLabel(_ image: FileGalleryImage) -> String {
        switch image.kind {
        case .rendered: return "Rendered thumbnail"
        case .designerPhoto: return "Designer photo — \(image.label ?? "photo")"
        case .uploaded: return "Your photo — \(image.label ?? "photo")"
        }
    }
}

/// The mockup's "Upload a photo" dialog — a plain file picker plus a drag-and-drop
/// target, working identically (no extra native permission dance beyond the picker
/// itself, which already grants read access to whatever's chosen).
private struct PhotoUploadSheet: View {
    let onUpload: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false
    @State private var pickedURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use Your Own Photo").font(.headline)
            Text("Pick an image from your computer to use as this file's thumbnail.")
                .font(.caption).foregroundStyle(.secondary)
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.25)))
                .frame(height: 120)
                .overlay {
                    VStack(spacing: 6) {
                        if let pickedURL {
                            Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                            Text(pickedURL.lastPathComponent).font(.caption).lineLimit(1)
                            Button("Choose a Different File…", action: chooseFile)
                                .buttonStyle(.link).font(.caption2)
                        } else {
                            Button("Choose File…", action: chooseFile)
                            Text("— or drag an image here").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    guard let url = urls.first else { return false }
                    pickedURL = url
                    return true
                } isTargeted: { isDropTargeted = $0 }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Upload & Use") {
                    if let pickedURL { onUpload(pickedURL) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(pickedURL == nil)
            }
        }
        .padding()
        .frame(width: 340)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            pickedURL = url
        }
    }
}
