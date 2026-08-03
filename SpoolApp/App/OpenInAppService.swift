import AppKit
import Foundation

/// Launches a file in a specific installed app — the entire native replacement for the
/// source app's `host-helper` `/open` endpoint (which existed only because a Docker
/// container can't launch a host GUI app at all). No allowlist needed the way
/// host-helper's `ALLOWED_APPS` was: `NSWorkspace.open` only ever launches an app the
/// user picked from `InstalledAppDetector`'s real, on-disk scan — there's no
/// caller-supplied app name to validate against.
enum OpenInAppService {
    /// Opens `fileURL` in a specific app.
    static func open(fileURL: URL, in app: DetectedApp) {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: app.url, configuration: configuration)
    }

    /// Opens `fileURL` with the system's default handler for its type — used for
    /// sidecar files (a README, a preview photo) that have no single obvious CAD/
    /// slicer app, mirroring the source app's `POST /open` with no `app` field.
    static func openWithDefaultApplication(fileURL: URL) {
        NSWorkspace.shared.open(fileURL)
    }

    /// Selects `fileURL` in a new (or already-open) Finder window — the standard
    /// "Reveal in Finder" action every Mac app that represents files on disk offers,
    /// almost always from a right-click context menu.
    static func revealInFinder(fileURL: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }
}
