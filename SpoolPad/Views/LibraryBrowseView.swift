import SpoolCore
import SwiftUI

struct LibraryBrowseView: View {
    @EnvironmentObject private var libraryAccess: LibraryAccess
    @StateObject private var viewModel = LibraryBrowseViewModel()
    @State private var showingPrintQueueSettings = false
    @State private var showingLibrarySettings = false

    var body: some View {
        NavigationSplitView {
            // Deliberately not `List(selection:)` — that initializer isn't available
            // on iOS for this free-form (row-of-`Label`s, not a single `ForEach`)
            // content shape. Plain buttons with manual selection styling sidestep the
            // platform-specific overload entirely and behave identically either way.
            List {
                sidebarRow(title: "All Files", systemImage: "square.grid.2x2", selection: .allFiles)
                if !viewModel.projects.isEmpty {
                    Section("Projects") {
                        ForEach(viewModel.projects) { project in
                            sidebarRow(title: project.name, systemImage: "folder", selection: .project(project.id ?? -1))
                        }
                    }
                }
            }
            .navigationTitle("Spool")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPrintQueueSettings = true
                    } label: {
                        Label("Print Queue Setup", systemImage: "printer")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLibrarySettings = true
                    } label: {
                        Label("Library Folder", systemImage: "folder.badge.gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingPrintQueueSettings) {
                PrintQueueSettingsView()
            }
            .sheet(isPresented: $showingLibrarySettings) {
                LibrarySettingsView()
            }
        } detail: {
            libraryDetail
        }
        .refreshable { await refresh() }
        .task {
            viewModel.reopenDatabase = {
                libraryAccess.reload()
                return libraryAccess.database
            }
            // The first open of an iCloud folder usually has to wait for downloads, so
            // keep checking for a while instead of making the user pull to refresh.
            await refresh()
            for _ in 0..<40 where libraryAccess.database == nil || viewModel.files.isEmpty {
                try? await Task.sleep(for: .seconds(3))
                await refresh()
            }
        }
        .onChange(of: viewModel.selection) { _, _ in Task { await viewModel.reloadFiles() } }
        .onChange(of: viewModel.searchQuery) { _, _ in Task { await viewModel.reloadFiles() } }
        .alert("Error", isPresented: Binding(
            get: { viewModel.lastError != nil },
            set: { if !$0 { viewModel.lastError = nil } }
        )) {
            Button("OK") { viewModel.lastError = nil }
        } message: {
            Text(viewModel.lastError ?? "")
        }
    }

    private func sidebarRow(title: String, systemImage: String, selection: LibrarySelection) -> some View {
        Button {
            viewModel.selection = selection
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                if viewModel.selection == selection {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var libraryDetail: some View {
        Group {
            if libraryAccess.database == nil {
                ContentUnavailableView(
                    "Waiting for Your Library",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Waiting for your Mac's shared library to export into this folder and download from iCloud. This can take a minute. Pull to check again.")
                )
            } else if viewModel.files.isEmpty {
                ContentUnavailableView(
                    "No Files Here",
                    systemImage: "tray",
                    description: Text("Nothing's been shared to this iPad yet — mark a project “Shared to iPad” on your Mac.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                        ForEach(viewModel.files, id: \.id) { file in
                            NavigationLink(value: file.id ?? -1) {
                                FileThumbnailCard(file: file)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationDestination(for: Int64.self) { fileId in
            if let file = viewModel.files.first(where: { $0.id == fileId }) {
                FileDetailView(file: file)
            }
        }
        .searchable(text: $viewModel.searchQuery, prompt: "Search")
    }

    private func refresh() async {
        libraryAccess.reload()
        await viewModel.refresh(database: libraryAccess.database)
    }
}

private struct FileThumbnailCard: View {
    let file: SpoolFile
    @EnvironmentObject private var libraryAccess: LibraryAccess

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                if let thumbnailPath = file.thumbnailPath,
                   let folderURL = libraryAccess.folderURL,
                   let uiImage = UIImage(contentsOfFile: folderURL.appendingPathComponent("Thumbnails/\(thumbnailPath)").path) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    Image(systemName: "cube")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            Text(file.displayName ?? file.filename)
                .font(.caption)
                .lineLimit(2)
        }
    }
}
