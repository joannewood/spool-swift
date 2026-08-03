import Foundation

/// Finds the bundled `step-tessellate` helper (a standalone OCCT-based CLI, built and
/// validated independently — see `Tools/StepConverter` — and copied into the app bundle
/// by an Xcode build phase). Mirrors `ArchiveToolLocator`'s "detect, degrade gracefully
/// if absent" posture rather than assuming the helper always exists: a dev build that
/// hasn't wired up the Copy Files phase yet, or a bundle built without it, should still
/// launch and just leave STEP files `render_status = 'unsupported'`.
public enum StepConverterLocator {
    public static func locate(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        guard let url = bundle.url(forResource: "step-tessellate", withExtension: nil) else { return nil }
        guard fileManager.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
}
