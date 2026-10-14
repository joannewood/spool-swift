import SwiftUI
import UniformTypeIdentifiers

/// One-time setup: grant access to the folder the Mac exports the shared library into
/// (typically an iCloud Drive folder both devices can already see). Nothing here talks
/// to the Mac directly — this just remembers a folder, the same way granting a watched
/// root does on the Mac side.
struct OnboardingView: View {
    @EnvironmentObject private var libraryAccess: LibraryAccess
    @State private var isPickingFolder = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "ipad.and.arrow.forward")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Set Up Spool")
                .font(.title).bold()
            Text("Choose the folder your Mac exports your shared 3D-printing library into — usually somewhere in iCloud Drive.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Choose Folder…") { isPickingFolder = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding()
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                libraryAccess.grantFolder(url)
            case .failure(let error):
                libraryAccess.lastError = "\(error)"
            }
        }
        .alert("Error", isPresented: Binding(
            get: { libraryAccess.lastError != nil },
            set: { if !$0 { libraryAccess.lastError = nil } }
        )) {
            Button("OK") { libraryAccess.lastError = nil }
        } message: {
            Text(libraryAccess.lastError ?? "")
        }
    }
}
