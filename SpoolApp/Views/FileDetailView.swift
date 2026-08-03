import AppKit
import SpoolCore
import SwiftUI

struct FileDetailView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var viewModel: FileDetailViewModel
    @Environment(\.undoManager) private var undoManager
    @State private var newTagText = ""
    @State private var showingAddTag = false
    @State private var newProjectName = ""
    @State private var showingNewProjectField = false
    @State private var showingAddRelationship = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var isAddTagFocused: Bool
    @FocusState private var isPrintLogCommentsFocused: Bool

    init(file: SpoolFile, environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: FileDetailViewModel(file: file, environment: environment))
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
                openInAppRow
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
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let previousName = viewModel.file.displayName ?? ""
                let newName = renameText
                performAndRegisterUndo(
                    actionName: "Rename",
                    forward: { await viewModel.rename(to: newName) },
                    backward: { await viewModel.rename(to: previousName) }
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only how it's shown in Spool changes — the file on disk keeps its real name.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            thumbnailImage
                .frame(width: 160, height: 160)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(viewModel.file.displayName ?? viewModel.file.filename).font(.title2).bold()
                    Button(action: {
                        renameText = viewModel.file.displayName ?? viewModel.file.filename
                        isRenaming = true
                    }) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                    .help("Rename (only how it's shown in Spool — the file on disk is never touched)")
                    .accessibilityLabel("Rename")
                }
                Text(viewModel.file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
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
                if viewModel.printLog?.printed == true {
                    printedBadge
                }
            }
            Spacer()
        }
    }

    /// Concrete, visible proof a "Printed" save actually took effect — reads straight
    /// from `viewModel.printLog` (refreshed after every save), not from the form's own
    /// input state, so it can't drift out of sync with what's actually persisted.
    private var printedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            Text("Printed")
            if let rating = viewModel.printLog?.rating {
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: star <= rating ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
                .accessibilityHidden(true)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(printedAccessibilityLabel)
    }

    private var printedAccessibilityLabel: String {
        guard let rating = viewModel.printLog?.rating else { return "Printed" }
        return "Printed, \(rating) of 5 stars"
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

    @ViewBuilder
    private var thumbnailImage: some View {
        if let path = viewModel.file.thumbnailPath,
           let image = NSImage(contentsOfFile: environment.thumbnailsDirectory.appendingPathComponent(path).path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(8)
        } else {
            VStack(spacing: 8) {
                RenderStatusIcon(status: viewModel.file.renderStatus, size: 40)
                Text(viewModel.file.ext.uppercased()).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var openInAppRow: some View {
        HStack(spacing: 12) {
            ForEach(viewModel.detectedApps) { app in
                Button(action: { viewModel.openInApp(app) }) {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(app.name)
                    }
                }
                .help("Open in \(app.name)")
            }
            if viewModel.detectedApps.isEmpty {
                Text("No CAD/slicer apps detected in /Applications").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: { OpenInAppService.revealInFinder(fileURL: URL(fileURLWithPath: viewModel.file.path)) }) {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .help("Show this file in Finder")
            ShareLink(item: URL(fileURLWithPath: viewModel.file.path)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .help("Share this file")
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
                .help("Add a tag")
                .accessibilityLabel("Add a tag")
            }
            FlowChips(items: viewModel.tags, label: { $0.name }, onRemove: { tag in
                performAndRegisterUndo(
                    actionName: "Remove Tag",
                    forward: { await viewModel.removeTag(tag) },
                    backward: { await viewModel.addTag(tag.name) }
                )
            })
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
                .fixedSize()
                .help("Add to a project")
                .accessibilityLabel("Add to a project")
            }
            FlowChips(items: viewModel.confirmedProjects, label: { $0.name }, onRemove: { project in
                performAndRegisterUndo(
                    actionName: "Remove from Project",
                    forward: { await viewModel.removeFromProject(project) },
                    backward: { await viewModel.addToProject(project) }
                )
            })

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

    private var printLogSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Printed").font(.headline)
            Toggle("I've printed this", isOn: $viewModel.printedInput)
            if viewModel.printedInput {
                HStack {
                    ForEach(1...5, id: \.self) { star in
                        // A real Button, not a bare `.onTapGesture` — a tap gesture on
                        // its own is invisible to VoiceOver and unreachable by keyboard,
                        // so this control was previously unusable without a mouse.
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

    private var relationshipsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Related Files").font(.headline)
                Spacer()
                Button(action: { showingAddRelationship = true }) {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .help("Add a relationship to another file")
                .accessibilityLabel("Add a relationship to another file")
            }
            ForEach(viewModel.confirmedRelationships, id: \.relationship.id) { pair in
                HStack {
                    Text("\(pair.relationship.type.rawValue.replacingOccurrences(of: "_", with: " ")): \(pair.otherFile.displayName ?? pair.otherFile.filename)")
                    Spacer()
                    Button(action: { removeRelationshipAndRegisterUndo(pair.relationship, otherFileId: pair.otherFile.id) }) {
                        Image(systemName: "xmark.circle.fill")
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

    var body: some View {
        if items.isEmpty {
            Text("None").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack {
                ForEach(items) { item in
                    HStack(spacing: 4) {
                        Text(label(item)).font(.caption)
                        Button(action: { onRemove(item) }) {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.plain)
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
