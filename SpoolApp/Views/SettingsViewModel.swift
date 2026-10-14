import Foundation
import SpoolCore
import SpoolFS

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var settings = AppSettings()
    @Published var rescanIntervalMinutesInput: Int = 5
    @Published var ipadExportIntervalMinutesInput: Int = 5
    /// Display-only — resolved from the bookmark just to show the user which folder is
    /// currently granted, not held open (the periodic export task resolves its own
    /// short-lived access each time it actually runs, see `AppEnvironment`).
    @Published private(set) var ipadExportFolderPath: String?
    @Published var lastError: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func load() async {
        do {
            settings = try await environment.appSettings.get()
            rescanIntervalMinutesInput = max(1, settings.rescanIntervalSeconds / 60)
            ipadExportIntervalMinutesInput = max(1, settings.ipadExportIntervalSeconds / 60)
            ipadExportFolderPath = settings.ipadExportFolderBookmarkData.flatMap {
                try? SecurityScopedBookmark.resolve($0).url.path
            }
        } catch {
            lastError = "\(error)"
        }
    }

    func saveRescanSettings(enabled: Bool) async {
        do {
            try await environment.appSettings.updateRescan(enabled: enabled, intervalSeconds: rescanIntervalMinutesInput * 60)
            settings = try await environment.appSettings.get()
        } catch { lastError = "\(error)" }
    }

    func saveAutoAcceptArchives(_ enabled: Bool) async {
        do {
            try await environment.appSettings.updateAutoAcceptArchives(enabled)
            settings = try await environment.appSettings.get()
        } catch { lastError = "\(error)" }
    }

    func saveIpadExportSettings(enabled: Bool) async {
        do {
            try await environment.appSettings.updateIpadExport(enabled: enabled, intervalSeconds: ipadExportIntervalMinutesInput * 60)
            settings = try await environment.appSettings.get()
        } catch { lastError = "\(error)" }
    }

    /// Same "pick a folder, grant access" flow watched roots use (`FolderPickerService`
    /// + `SecurityScopedBookmark`) — this folder isn't a watched root (nothing here
    /// gets ingested from it), just a destination `IPadExportService` writes into, so it
    /// gets its own bookmark rather than a `WatchedRoot` row.
    func grantIpadExportFolder() async {
        guard let url = FolderPickerService.pickFolder(
            prompt: "Grant Access",
            message: "Choose (or create) a folder synced to your iPad — via iCloud Drive or similar — for Spool to export a shared library into."
        ) else { return }
        do {
            let bookmarkData = try SecurityScopedBookmark.create(for: url)
            try await environment.appSettings.updateIpadExportFolderBookmark(bookmarkData)
            settings = try await environment.appSettings.get()
            ipadExportFolderPath = url.path
        } catch { lastError = "\(error)" }
    }

    func clearIpadExportFolder() async {
        do {
            try await environment.appSettings.updateIpadExportFolderBookmark(nil)
            settings = try await environment.appSettings.get()
            ipadExportFolderPath = nil
        } catch { lastError = "\(error)" }
    }
}
