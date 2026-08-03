import Foundation
import SpoolCore
import SpoolFS

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var settings = AppSettings()
    @Published var rescanIntervalMinutesInput: Int = 5
    @Published var lastError: String?
    /// Resolved fresh from `settings.archiveToolBookmarkData` for display only — the
    /// actual access Spool *uses* was already resolved once at launch (see
    /// `AppEnvironment.resolveArchiveToolAccess`); this never needs its own security
    /// scope held open, just a path to show the user what's currently configured.
    @Published private(set) var archiveToolPath: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func load() async {
        do {
            settings = try await environment.appSettings.get()
            rescanIntervalMinutesInput = max(1, settings.rescanIntervalSeconds / 60)
            refreshArchiveToolPath()
        } catch {
            lastError = "\(error)"
        }
    }

    private func refreshArchiveToolPath() {
        guard let data = settings.archiveToolBookmarkData else {
            archiveToolPath = nil
            return
        }
        archiveToolPath = (try? SecurityScopedBookmark.resolve(data))?.url.path
    }

    func grantArchiveTool(url: URL) async {
        do {
            let data = try SecurityScopedBookmark.create(for: url)
            try await environment.appSettings.updateArchiveToolBookmark(data)
            settings = try await environment.appSettings.get()
            refreshArchiveToolPath()
        } catch { lastError = "\(error)" }
    }

    func clearArchiveTool() async {
        do {
            try await environment.appSettings.updateArchiveToolBookmark(nil)
            settings = try await environment.appSettings.get()
            refreshArchiveToolPath()
        } catch { lastError = "\(error)" }
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
}
