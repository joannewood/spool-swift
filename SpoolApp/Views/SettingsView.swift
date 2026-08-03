import SpoolCore
import SwiftUI

/// The standard macOS Settings window (⌘,) — split out from the Admin review panel
/// because these are two different kinds of screens: Admin is an inbox ("here's what
/// needs a decision right now"), Settings is configuration you set once and forget.
/// Folding "Sync" into Admin's own sidebar meant ⌘, — the one keyboard shortcut every
/// Mac user reaches for instinctively when they want to change how an app behaves —
/// did nothing at all.
///
/// Watched-folder management (add/rename/pause/remove) lives here too, in its own tab —
/// it moved out of the main window's sidebar, which now only shows a glanceable,
/// non-interactive summary (see `WatchedFolderSummaryRow` in ContentView.swift). Folders
/// are closer to "accounts" (compare Mail's Settings → Accounts) than browsable content:
/// a short, infrequently-changed list you configure rather than navigate, and moving
/// their management here follows the same "Settings is configuration, not content" split
/// that separated Admin's review queues from Settings' actual preferences.
struct SettingsView: View {
    @StateObject private var viewModel: SettingsViewModel
    @EnvironmentObject private var rootsViewModel: RootsViewModel

    init(environment: AppEnvironment) {
        _viewModel = StateObject(wrappedValue: SettingsViewModel(environment: environment))
    }

    var body: some View {
        TabView {
            GeneralSettingsPane(viewModel: viewModel)
                .tabItem { Label("General", systemImage: "gearshape") }
            FoldersSettingsPane(rootsViewModel: rootsViewModel)
                .tabItem { Label("Folders", systemImage: "folder") }
        }
        .frame(width: 480, height: 420)
        .task { await viewModel.load() }
        .task { await rootsViewModel.refresh() }
        // A real two-way `Binding`, not `.constant(viewModel.lastError != nil)` — the
        // latter's setter is a no-op, so when SwiftUI's own dismissal machinery tries
        // to write `false` back through it (not just the OK button's action), that
        // write happens mid-transaction with nowhere to go. Confirmed live as a real,
        // if intermittent, trigger for "Publishing changes from within view updates is
        // not allowed" — this exact anti-pattern was duplicated across five views.
        .alert("Error", isPresented: Binding(
            get: { viewModel.lastError != nil },
            set: { if !$0 { viewModel.lastError = nil } }
        ), actions: {
            Button("OK") { viewModel.lastError = nil }
        }, message: { Text(viewModel.lastError ?? "") })
    }
}

private struct GeneralSettingsPane: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("Watching") {
                Toggle("Watch for changes automatically", isOn: Binding(
                    get: { viewModel.settings.rescanEnabled },
                    set: { newValue in Task { await viewModel.saveRescanSettings(enabled: newValue) } }
                ))
                .help("When on, Spool periodically re-scans your folders for changes made outside the app")
                Stepper(
                    "Rescan every \(viewModel.rescanIntervalMinutesInput) minute\(viewModel.rescanIntervalMinutesInput == 1 ? "" : "s")",
                    value: $viewModel.rescanIntervalMinutesInput, in: 1...60
                )
                .disabled(!viewModel.settings.rescanEnabled)
                .onChange(of: viewModel.rescanIntervalMinutesInput) { _, _ in
                    Task { await viewModel.saveRescanSettings(enabled: viewModel.settings.rescanEnabled) }
                }
            }
            Section("Archives") {
                Toggle("Automatically extract every new relevant archive", isOn: Binding(
                    get: { viewModel.settings.autoAcceptArchives },
                    set: { newValue in Task { await viewModel.saveAutoAcceptArchives(newValue) } }
                ))
                .help("Skip the Archives review queue and extract zip files as soon as a 3D-printing file is found inside")
                ArchiveToolPickerRow(viewModel: viewModel)
            }
        }
        .formStyle(.grouped)
    }
}

/// Optional — Spool works fine with this unconfigured, .7z/.rar archives just show as
/// unsupported. Zip needs no external tool at all; this exists purely to *also* support
/// the two archive formats macOS has no native or pure-Swift reader for, if the user
/// happens to have `unar` or `7z` installed (e.g. via Homebrew). Needs the user to
/// explicitly grant the binary via `NSOpenPanel` (not just a fixed-path check) because
/// the sandboxed app has no other access to a path like `/opt/homebrew/bin/unar` — see
/// `ArchiveToolLocator`.
private struct ArchiveToolPickerRow: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = viewModel.archiveToolPath {
                Text("Using \((path as NSString).lastPathComponent) for .7z/.rar archives")
                    .font(.caption)
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack {
                    Button("Change…") { locate() }
                    Button("Remove") { Task { await viewModel.clearArchiveTool() } }
                }
            } else {
                Text("Optional — lets Spool also recognize .7z/.rar archives worth reviewing, if you have unar or 7z installed. Without it, they're still tracked, just marked unsupported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Locate unar or 7z…") { locate() }
            }
        }
        .padding(.top, 2)
    }

    private func locate() {
        guard let url = FolderPickerService.pickFile(
            prompt: "Choose",
            message: "Choose the unar or 7z executable — used to recognize .7z/.rar archives worth reviewing. Takes effect after restarting Spool."
        ) else { return }
        Task { await viewModel.grantArchiveTool(url: url) }
    }
}

/// The Folders pane — same "list with a small + at the bottom-left" shape System
/// Settings itself uses for managing a short list (Internet Accounts, Users & Groups),
/// rather than inventing a bespoke layout.
private struct FoldersSettingsPane: View {
    @ObservedObject var rootsViewModel: RootsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(rootsViewModel.roots) { root in
                    RootManagementRow(
                        root: root,
                        onRemove: { Task { await rootsViewModel.remove(root) } },
                        onUpdate: { label, ingestMode, active in
                            Task { await rootsViewModel.update(root, label: label, ingestMode: ingestMode, active: active) }
                        }
                    )
                }
                if rootsViewModel.roots.isEmpty {
                    Text("No folders yet — add one below to get started.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .listStyle(.inset)
            Divider()
            HStack {
                AddFolderMenu(viewModel: rootsViewModel) {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .help("Add a watched folder")
                .accessibilityLabel("Add a watched folder")
                Spacer()
            }
            .padding(8)
        }
    }
}

/// The three folder kinds share the exact same "pick a folder, grant access" flow but
/// mean very different things for how Spool treats what's inside — worth explaining
/// inline rather than assuming the names are self-evident.
private struct AddFolderMenu<Label: View>: View {
    let viewModel: RootsViewModel
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Button("Drop Folder…") { Task { await viewModel.addRoot(kind: .dropFolder, label: "Drop Folder") } }
                .help(RootKind.dropFolder.explanation)
            Button("Library (Read-Only)…") { Task { await viewModel.addRoot(kind: .library, label: "Library") } }
                .help(RootKind.library.explanation)
            Button("Downloads…") { Task { await viewModel.addRoot(kind: .downloads, label: "Downloads") } }
                .help(RootKind.downloads.explanation)
        } label: {
            label()
        }
    }
}

/// The full management row for one watched root — rename, pause, (for a library folder)
/// change how new files are handled, or stop watching it entirely.
private struct RootManagementRow: View {
    let root: WatchedRoot
    let onRemove: () -> Void
    let onUpdate: (String, RootIngestMode, Bool) -> Void
    @State private var showingRemoveConfirmation = false
    @State private var showingEdit = false
    @State private var editedLabel = ""
    @State private var editedIngestMode: RootIngestMode = .indexInPlace
    @State private var editedActive = true

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(root.label).font(.body)
                    Text(root.kind.shortLabel)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(.quaternary))
                        .foregroundStyle(.secondary)
                    if !root.active {
                        Text("Paused")
                            .font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(.orange.opacity(0.2)))
                            .foregroundStyle(.orange)
                    }
                }
                Text(root.hostPath).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .help(root.kind.explanation)
            .opacity(root.active ? 1 : 0.5)
            Spacer()
            Button {
                editedLabel = root.label
                editedIngestMode = root.ingestMode
                editedActive = root.active
                showingEdit = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Rename, pause, or (for a library folder) change how new files are handled")
            .accessibilityLabel("Edit \(root.label)")
            Button(role: .destructive, action: { showingRemoveConfirmation = true }) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Stop watching this folder")
            .accessibilityLabel("Stop watching \(root.label)")
        }
        .confirmationDialog(
            "Stop watching “\(root.label)”?",
            isPresented: $showingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop Watching", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            // The files on disk are never touched, but this does cascade-delete every
            // indexed row for this root — tags, project membership, print history —
            // not just "stop showing these files," so it's worth spelling out.
            Text("This removes all of its files from your library, along with any tags, projects, and print history you've added for them. The files themselves are never touched on disk.")
        }
        .popover(isPresented: $showingEdit) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit “\(root.label)”").font(.headline)
                TextField("Label", text: $editedLabel)
                    .textFieldStyle(.roundedBorder)
                Toggle("Watching", isOn: $editedActive)
                    .help("Pause to stop watching without losing this folder's tags, projects, or print history")
                if root.kind == .library {
                    Picker("New files", selection: $editedIngestMode) {
                        Text("Index in place").tag(RootIngestMode.indexInPlace)
                        Text("Move into drop folder").tag(RootIngestMode.relocateToDropfolder)
                    }
                    .pickerStyle(.radioGroup)
                }
                HStack {
                    Spacer()
                    Button("Save") {
                        onUpdate(editedLabel, editedIngestMode, editedActive)
                        showingEdit = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(width: 280)
        }
    }
}
