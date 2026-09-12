import Foundation

/// A CAD/slicer app found on disk, ready to be offered as an "open in…" target.
struct DetectedApp: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    /// `nil` means "offer for every file type" (the default for most CAD/slicer apps,
    /// which happily open most model formats); a non-nil set restricts the button to
    /// only those extensions — e.g. EufyMake Studio only imports STL/3MF.
    let allowedExtensions: Set<String>?
}

/// Scans `/Applications` and `~/Applications` for CAD/slicer app bundles — the native
/// replacement for the source app's `host-helper/configure_apps.py`, which had to scan
/// from *inside* a launchd agent specifically because Docker containers can't see the
/// host's `/Applications` at all. A native app just reads the filesystem directly, no
/// separate helper process needed.
enum InstalledAppDetector {
    private struct AppMatcher {
        let keyword: String
        var allowedExtensions: Set<String>?
    }

    /// Keyword groups for common CAD/slicer apps — matched case-insensitively against
    /// each `.app` bundle's display name. Not exhaustive; easy to extend.
    private static let matchers: [AppMatcher] = [
        AppMatcher(keyword: "fusion", allowedExtensions: nil),
        AppMatcher(keyword: "fusion 360", allowedExtensions: nil),
        AppMatcher(keyword: "bambu studio", allowedExtensions: nil),
        AppMatcher(keyword: "bambustudio", allowedExtensions: nil),
        AppMatcher(keyword: "prusaslicer", allowedExtensions: nil),
        AppMatcher(keyword: "orcaslicer", allowedExtensions: nil),
        AppMatcher(keyword: "superslicer", allowedExtensions: nil),
        AppMatcher(keyword: "cura", allowedExtensions: nil),
        AppMatcher(keyword: "chitubox", allowedExtensions: nil),
        AppMatcher(keyword: "simplify3d", allowedExtensions: nil),
        AppMatcher(keyword: "openscad", allowedExtensions: nil),
        AppMatcher(keyword: "meshmixer", allowedExtensions: nil),
        // No SVG/SCAD — EufyMake Studio doesn't import either.
        AppMatcher(keyword: "eufymake", allowedExtensions: ["stl", "3mf", "obj", "step", "stp", "gcode"]),
    ]

    /// Bundle-name substrings that mean "this is plumbing around the real app, not the
    /// app itself" — mirrors the source app's noise filter for installer/uninstaller/
    /// updater bundles that would otherwise clutter the picker.
    private static let noiseSubstrings = ["install", "uninstall", "updater", "helper"]

    static func detectAll(fileManager: FileManager = .default) -> [DetectedApp] {
        let searchDirectories = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]

        var found: [DetectedApp] = []
        var seenPaths: Set<String> = []
        for directory in searchDirectories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for url in entries where url.pathExtension.lowercased() == "app" {
                let name = url.deletingPathExtension().lastPathComponent
                let lowered = name.lowercased()
                guard let matcher = matchers.first(where: { lowered.contains($0.keyword) }) else { continue }
                guard !noiseSubstrings.contains(where: { lowered.contains($0) }) else { continue }
                guard !seenPaths.contains(url.path) else { continue }
                seenPaths.insert(url.path)
                found.append(DetectedApp(name: name, url: url, allowedExtensions: matcher.allowedExtensions))
            }
        }
        return found.sorted { $0.name < $1.name }
    }
}
