import SpoolCore
import SwiftUI

/// Read-only — no editing, no tagging, no ingest. Everything here is exactly what a
/// kid needs to decide "is this the thing I want to print": photos, what it's tagged/
/// grouped under, its print settings if any, and a way to hand the actual file off to
/// a slicer app or AirDrop it to the Mac.
struct FileDetailView: View {
    let file: SpoolFile
    @EnvironmentObject private var libraryAccess: LibraryAccess
    @StateObject private var viewModel = FileDetailViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                gallery
                Text(file.displayName ?? file.filename)
                    .font(.title2).bold()

                if !viewModel.tags.isEmpty {
                    FlowLabelsView(title: "Tags", items: viewModel.tags.map(\.name))
                }
                if !viewModel.projects.isEmpty {
                    FlowLabelsView(title: "Projects", items: viewModel.projects.map(\.name))
                }
                if let metadata = viewModel.printMetadata {
                    printMetadataSection(metadata)
                }
            }
            .padding()
        }
        .navigationTitle(file.displayName ?? file.filename)
        .toolbar {
            if let localFileURL = viewModel.localFileURL {
                ShareLink(item: localFileURL) {
                    Label("Print / Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .task { await viewModel.load(file: file, database: libraryAccess.database, folderURL: libraryAccess.folderURL) }
    }

    @ViewBuilder
    private var gallery: some View {
        let images = viewModel.galleryImages
        if images.isEmpty, let thumbnailPath = file.thumbnailPath {
            thumbnailImage(named: thumbnailPath)
        } else if !images.isEmpty {
            TabView {
                ForEach(images, id: \.id) { image in
                    thumbnailImage(named: image.thumbnailPath)
                }
            }
            .tabViewStyle(.page)
            .frame(height: 320)
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .frame(height: 240)
                .overlay(Image(systemName: "cube").font(.system(size: 48)).foregroundStyle(.secondary))
        }
    }

    private func thumbnailImage(named filename: String) -> some View {
        Group {
            if let folderURL = libraryAccess.folderURL,
               let uiImage = UIImage(contentsOfFile: folderURL.appendingPathComponent("Thumbnails/\(filename)").path) {
                Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                    .overlay(Image(systemName: "cube").font(.system(size: 48)).foregroundStyle(.secondary))
            }
        }
        .frame(height: 240)
    }

    private func printMetadataSection(_ metadata: PrintMetadata) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Print Settings").font(.headline)
            if let material = metadata.material { LabeledContent("Material", value: material) }
            if let printerProfile = metadata.printerProfile { LabeledContent("Printer", value: printerProfile) }
            if let slicer = metadata.slicer { LabeledContent("Slicer", value: slicer) }
        }
    }
}

/// A simple wrapping row of read-only labels — tags/projects here are display-only, no
/// tap-to-navigate or remove affordance (that's the Mac app's job).
private struct FlowLabelsView: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(.quaternary))
                }
            }
        }
    }
}
