import AppKit
import SpoolCore
import SwiftUI

enum SidebarSelection: Hashable {
    case allFiles
    case allProjects
    case project(Int64)
}

struct ContentView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var rootAccess: RootAccessManager
    @EnvironmentObject private var viewModel: RootsViewModel
    @EnvironmentObject private var projectsViewModel: ProjectsViewModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var jobStatus = MenuBarStatusViewModel()
    @State private var selection: SidebarSelection? = .allFiles
    // Owned here (not inside LibraryGridView) because a `NavigationStack` only lets
    // its *own* root push onto a path passed in from outside — this is what lets the
    // grid's keyboard "open" action push a destination the same way a click does.
    @State private var libraryPath = NavigationPath()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    Label("All Files", systemImage: "shippingbox").tag(SidebarSelection.allFiles)
                }
                Section {
                    Label("All Projects", systemImage: "square.grid.2x2").tag(SidebarSelection.allProjects)
                    ForEach(projectsViewModel.children(ofParentId: nil)) { project in
                        ProjectTreeRow(project: project, viewModel: projectsViewModel)
                    }
                    if projectsViewModel.allProjects.isEmpty {
                        Text("No projects yet.").foregroundStyle(.secondary).font(.callout)
                    }
                } header: {
                    HStack {
                        Text("Projects")
                        Spacer()
                        NewProjectButton(viewModel: projectsViewModel)
                    }
                }
                Section {
                    ForEach(viewModel.roots) { root in
                        WatchedFolderSummaryRow(root: root)
                    }
                    if viewModel.roots.isEmpty {
                        Text("No folders yet — add one in Settings.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                } header: {
                    HStack {
                        Text("Watched Folders")
                        Spacer()
                        // Renaming, pausing, and adding folders all moved to Settings —
                        // this is a glanceable "what's watched and why is it read-only/
                        // paused" reference for while you're browsing, not a management
                        // UI, so the only action left here is a shortcut to where the
                        // real controls live.
                        SettingsLink { Image(systemName: "gearshape") }
                            .buttonStyle(.plain)
                            .help("Manage watched folders in Settings")
                            .accessibilityLabel("Manage watched folders in Settings")
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
            .toolbar {
                ToolbarItem {
                    // A real window (opened, not presented) so triaging duplicates/
                    // suggestions/archives doesn't block glancing back at the library —
                    // `Window`'s single-instance guarantee means clicking this again
                    // while Admin is already open just brings it forward. The overlaid
                    // count is the only glance-visible sign of ingestion activity in the
                    // main window at all — everything else about the job queue lives
                    // behind this button, in Admin. SwiftUI's `.badge()` was considered
                    // instead of this hand-rolled circle, but it only renders inside
                    // List rows/TabView items, not on a bare toolbar Button.
                    Button("Admin", systemImage: "wrench.and.screwdriver") { openWindow(id: WindowID.admin) }
                        .labelStyle(.iconOnly)
                        .help(adminButtonHelp)
                        .accessibilityLabel(adminButtonHelp)
                        .overlay(alignment: .topTrailing) {
                            if jobStatus.pendingJobCount > 0 {
                                Text("\(min(jobStatus.pendingJobCount, 99))")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(3)
                                    .background(Circle().fill(.red))
                                    .offset(x: 8, y: -8)
                                    .accessibilityHidden(true)
                            }
                        }
                }
            }
        } detail: {
            NavigationStack(path: $libraryPath) {
                switch selection {
                case .project(let projectId):
                    ProjectDetailView(projectId: projectId, selection: $selection)
                case .allProjects:
                    ProjectsOverviewView(selection: $selection)
                case .allFiles, .none:
                    LibraryGridView(selection: $selection, navigationPath: $libraryPath)
                }
            }
            // The path only ever means something in the library-grid context (a
            // pushed file id) — switching to a different sidebar item without
            // clearing it first would leave a stale destination the new root never
            // registered a handler for.
            .onChange(of: selection) { _, _ in libraryPath = NavigationPath() }
        }
        // A floor for both dimensions — without it, the sidebar/detail split and the
        // grid's own minimum column width can be squeezed into an overlapping, broken
        // layout well before the window becomes too small to be useful.
        .frame(minWidth: 820, minHeight: 500)
        .alert("Error", isPresented: .constant(viewModel.lastError != nil), actions: {
            Button("OK") { viewModel.lastError = nil }
        }, message: {
            Text(viewModel.lastError ?? "")
        })
        .task {
            await viewModel.refresh()
        }
        .task {
            await projectsViewModel.load()
        }
        .task {
            jobStatus.start(writer: environment.database.writer)
        }
    }

    private var adminButtonHelp: String {
        let base = "Review duplicates, suggestions, archives, and settings"
        guard jobStatus.pendingJobCount > 0 else { return base }
        let jobsLabel = jobStatus.pendingJobCount == 1 ? "1 job" : "\(jobStatus.pendingJobCount) jobs"
        return "\(base) — \(jobsLabel) running"
    }
}

/// The three folder kinds share the exact same "pick a folder, grant access" flow but
/// mean very different things for how Spool treats what's inside — worth explaining
/// inline rather than assuming the names are self-evident. Non-private (unlike most of
/// this file's helpers) because `SettingsView`'s Folders pane needs it too, for both its
/// own `AddFolderMenu` and the management row's tooltip.
extension RootKind {
    var explanation: String {
        switch self {
        case .dropFolder:
            return "Files here are indexed and can be freely reorganized — moved, tagged, or deleted from within Spool."
        case .library:
            return "Files here are indexed but Spool never modifies, moves, or deletes them — safe for a folder you don't want touched."
        case .downloads:
            return "New 3D-printing files here are automatically moved into your drop folder once indexed, keeping Downloads tidy."
        }
    }

    var shortLabel: String {
        switch self {
        case .dropFolder: return "Drop Folder"
        case .library: return "Library (read-only)"
        case .downloads: return "Downloads"
        }
    }
}

/// A glanceable, non-interactive summary of one watched root — renaming, pausing, and
/// removing all moved to Settings' Folders pane (see `RootManagementRow` there); this is
/// just enough context to explain, at a glance while browsing, why a file is read-only
/// or why a folder's contents have stopped updating.
private struct WatchedFolderSummaryRow: View {
    let root: WatchedRoot

    var body: some View {
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
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var status = MenuBarStatusViewModel()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Spool").font(.headline)
            Text(statusLine).font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Open Library") { openLibrary() }
            Button("Open Admin") { openWindow(id: WindowID.admin) }
            Divider()
            Button("Quit Spool") { NSApp.terminate(nil) }
        }
        .padding(8)
        .task { status.start(writer: environment.database.writer) }
    }

    private var statusLine: String {
        switch status.pendingJobCount {
        case 0: return "Up to date"
        case 1: return "1 file pending"
        default: return "\(status.pendingJobCount) files pending"
        }
    }

    // `openWindow(id:)` always creates a *new* WindowGroup window rather than
    // bringing an existing one forward (WindowGroup is a group by design, unlike the
    // singleton `Window` used for Admin) — so this checks for an already-visible
    // library window first and just activates the app in that case, only falling
    // back to `openWindow` for the "closed the last window, app's still running in
    // the background" case this menu exists for in the first place.
    private func openLibrary() {
        if hasVisibleLibraryWindow() {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: WindowID.main)
        }
    }

    private func hasVisibleLibraryWindow() -> Bool {
        NSApp.windows.contains { window in
            window.isVisible
                && window.identifier?.rawValue != WindowID.admin
                && !(window is NSPanel)
                && window.styleMask.contains(.titled)
                && window.styleMask.contains(.resizable)
        }
    }
}
