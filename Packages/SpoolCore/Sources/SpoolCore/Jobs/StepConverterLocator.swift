import Foundation

/// Finds the bundled `step-tessellate` helper (a standalone OCCT-based CLI, built and
/// validated independently — see `Tools/StepConverter` — and copied into the app bundle
/// by an Xcode build phase). "Detect, degrade gracefully if absent" rather than assuming
/// the helper always exists: a dev build that hasn't wired up the Copy Files phase yet,
/// or a bundle built without it, should still launch and just leave STEP files
/// `render_status = 'unsupported'`.
///
/// Bundling is why this one actually works where the archive-tool equivalent didn't:
/// a same-signature helper *inside* the app's own bundle isn't subject to the App
/// Sandbox restriction that blocks executing an arbitrary external, user-selected
/// binary (see `ArchiveInspectionService`'s doc comment) — it never needed a
/// security-scoped bookmark or process-execute rights over anything outside the bundle.
public enum StepConverterLocator {
    public static func locate(bundle: Bundle = .main, fileManager: FileManager = .default) -> URL? {
        guard let url = bundle.url(forResource: "step-tessellate", withExtension: nil) else { return nil }
        guard fileManager.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }
}
