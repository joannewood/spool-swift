import AppKit
import Foundation

/// Thin wrapper over `NSOpenPanel` — the app-target-only piece of onboarding a watched
/// root (SpoolCore/SpoolFS stay AppKit-free so they're plain-`swift test`-able).
enum FolderPickerService {
    @MainActor
    static func pickFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = "Grant Spool access to this folder. It's remembered across launches."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Used for the optional "locate unar/7z" picker in Settings — a single executable
    /// file rather than a folder, defaulting to Homebrew's usual install locations so
    /// the user isn't hunting for it.
    @MainActor
    static func pickFile(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = message
        for candidate in ["/opt/homebrew/bin", "/usr/local/bin"] where FileManager.default.fileExists(atPath: candidate) {
            panel.directoryURL = URL(fileURLWithPath: candidate)
            break
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
