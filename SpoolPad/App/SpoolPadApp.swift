import SwiftUI

@main
struct SpoolPadApp: App {
    @StateObject private var libraryAccess = LibraryAccess()
    @StateObject private var printQueueSettings = PrintQueueSettings()

    var body: some Scene {
        WindowGroup {
            Group {
                if libraryAccess.isConfigured {
                    LibraryBrowseView()
                } else {
                    OnboardingView()
                }
            }
            .environmentObject(libraryAccess)
            .environmentObject(printQueueSettings)
        }
    }
}
