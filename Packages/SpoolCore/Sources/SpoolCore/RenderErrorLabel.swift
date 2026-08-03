import Foundation

/// Short, human-readable category for a failed render's raw `files.render_error` text,
/// shown in the thumbnail placeholder instead of the bare word "failed" — mirrors the
/// source app's `spool_api/filters.py::render_error_label`. Recognizes the two
/// mesh-safety-guard error shapes (an oversized mesh vs. a 3MF component tree that
/// would blow up into far more geometry than its file size suggests, see
/// `ThreeMFReader.ThreeMFError`'s descriptions); anything else (a real bug, a malformed
/// file) falls back to a generic label — the raw text is still available separately
/// (e.g. a tooltip) for anyone who needs it.
public enum RenderErrorLabel {
    public static func label(for errorText: String?) -> String {
        let text = errorText ?? ""
        if text.contains("uncompressed"), text.contains("safety limit") {
            return "Mesh too large to render"
        }
        if text.contains("build references"), text.contains("safety limit") {
            return "Too complex to render"
        }
        return "Render failed"
    }
}
