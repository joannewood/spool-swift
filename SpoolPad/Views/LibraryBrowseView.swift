import SpoolCore
import SwiftUI

struct LibraryBrowseView: View {
    @EnvironmentObject private var libraryAccess: LibraryAccess
    @StateObject private var viewModel = LibraryBrowseViewModel()

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
        } detail: {
            libraryDetail
        }
        .refreshable { await refresh() }
        .task { await refresh() }
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
                    description: Text("Your Mac hasn't exported a shared library into this folder yet. Pull to check again.")
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
