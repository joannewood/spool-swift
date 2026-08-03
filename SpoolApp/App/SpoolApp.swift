import SwiftUI

/// Keeps the app (and its watching/ingestion, once M1 lands) running after the browse
/// window is closed — closing the window is not the same as quitting. This is the
/// entire replacement for the source app's always-on Docker `watcher`/`worker`
/// containers: one long-lived process, no daemon, no XPC service.
final class SpoolAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct SpoolApp: App {
    @NSApplicationDelegateAdaptor(SpoolAppDelegate.self) private var appDelegate
    @StateObject private var environment: AppEnvironment
    @StateObject private var rootsViewModel: RootsViewModel
    @StateObject private var projectsViewModel: ProjectsViewModel
    @Environment(\.openWindow) private var openWindow

    init() {
        // AppEnvironment.init opens/migrates the on-disk database — a failure here
        // means the app genuinely can't run, so surfacing it as a crash during
        // development is preferable to limping along with no persistence.
        let environment = try! AppEnvironment()
        _environment = StateObject(wrappedValue: environment)
        // Built here (not inside ContentView) because SwiftUI won't let a view read
        // @EnvironmentObject from its own init — this is the one place both
        // `environment.watchedRoots` and `environment.rootAccess` are already
        // concrete values, not yet-to-be-injected environment objects.
        _rootsViewModel = StateObject(wrappedValue: RootsViewModel(
            repository: environment.watchedRoots,
            rootAccess: environment.rootAccess,
            backfill: environment.backfill,
            liveWatch: environment.liveWatch
        ))
        _projectsViewModel = StateObject(wrappedValue: ProjectsViewModel(environment: environment))
    }

    var body: some Scene {
        WindowGroup(id: WindowID.main) {
            ContentView()
                .environmentObject(environment)
                .environmentObject(environment.rootAccess)
                .environmentObject(rootsViewModel)
                .environmentObject(projectsViewModel)
                .task { await environment.start() }
        }
        .commands {
            // The menu bar is always reachable regardless of window size or toolbar
            // state, unlike the sidebar's icon-only "+" button — this is the
            // authoritative, always-discoverable way to grant a folder on macOS.
            CommandGroup(after: .newItem) {
                Button("Add Drop Folder…") {
                    Task { await rootsViewModel.addRoot(kind: .dropFolder, label: "Drop Folder") }
                }
                Button("Add Library Folder (Read-Only)…") {
                    Task { await rootsViewModel.addRoot(kind: .library, label: "Library") }
                }
                Button("Add Downloads Folder…") {
                    Task { await rootsViewModel.addRoot(kind: .downloads, label: "Downloads") }
                }
            }
            // Standard Mac convention for a utility panel: reachable from the Window
            // menu (alongside every other open/openable window), not just a toolbar
            // button that's easy to miss if you don't already know it's there.
            CommandGroup(after: .windowArrangement) {
                Button("Admin") { openWindow(id: WindowID.admin) }
                    .keyboardShortcut("a", modifiers: [.command, .option])
            }
        }

        // A real singleton window, not a sheet blocking the main library window —
        // triaging duplicates/suggestions/archives is exactly the kind of persistent,
        // side-by-side review task the sheet used to make impossible (you couldn't
        // glance back at the library while the sheet was up). `Window` (rather than
        // `WindowGroup`) guarantees exactly one instance: re-opening it via the
        // toolbar or menu just brings the existing one forward instead of spawning a
        // duplicate, matching how a single-instance Mac utility panel behaves.
        Window("Admin", id: WindowID.admin) {
            AdminView(environment: environment)
                .environmentObject(environment)
        }
        .defaultSize(width: 720, height: 560)

        // The `Settings` scene is how SwiftUI wires up ⌘, and the app-menu "Settings…"
        // item for free — there is no separate command to register for it. `Settings`
        // is a separate Scene from the main WindowGroup, so it doesn't automatically
        // inherit that WindowGroup's environment objects — `rootsViewModel` needs
        // explicit injection here too, same as `environment` did for the Admin window.
        Settings {
            SettingsView(environment: environment)
                .environmentObject(rootsViewModel)
        }

        MenuBarExtra("Spool", systemImage: "shippingbox") {
            MenuBarContentView()
                .environmentObject(environment)
        }
    }
}

enum WindowID {
    static let main = "main"
    static let admin = "admin"
}
