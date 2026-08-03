import Foundation
import SpoolCore

@MainActor
final class SettingsViewModel: ObservableObject {
    @Published private(set) var settings = AppSettings()
    @Published var rescanIntervalMinutesInput: Int = 5
    @Published var lastError: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func load() async {
        do {
            settings = try await environment.appSettings.get()
            rescanIntervalMinutesInput = max(1, settings.rescanIntervalSeconds / 60)
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
}
