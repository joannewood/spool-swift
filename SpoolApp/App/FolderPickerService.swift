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
}
