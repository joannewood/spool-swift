import SwiftUI

/// Shows which folder this iPad is currently reading its library from, and lets you
/// unlink it to pick a different one. Separate from the Mac-side "Shared to iPad"
/// toggle in `ProjectsView` there, which controls *what* gets exported into that
/// folder, not *which* folder this app reads from.
struct LibrarySettingsView: View {
    @EnvironmentObject private var libraryAccess: LibraryAccess
    @Environment(\.dismiss) private var dismiss
    @State private var showingChangeConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Linked Folder", value: libraryAccess.folderURL?.lastPathComponent ?? "Not set")
                } footer: {
                    Text("This is the folder your Mac exports your shared library into — usually somewhere in iCloud Drive.")
                }
                Section {
                    Button("Change Folder…", role: .destructive) { showingChangeConfirmation = true }
                } footer: {
                    Text("You'll be asked to pick a folder again, the same way as first-time setup.")
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog(
            "Change the linked folder?",
            isPresented: $showingChangeConfirmation,
            titleVisibility: .visible
        ) {
            // Resetting flips `libraryAccess.isConfigured` to false, which
            // `SpoolPadApp`'s root view switch already reacts to by swapping this
            // whole view out for `OnboardingView` — no need to also drive a picker
            // from here.
            Button("Change Folder…", role: .destructive) { libraryAccess.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll need to pick a folder again before you can browse your library.")
        }
    }
}
