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
    /// `.knownLimit` is one of the two mesh-safety guards deliberately rejecting a file
    /// to avoid the OOM crash loops those guards exist to prevent — working as
    /// designed, not a bug. `.unexpected` is everything else: a real parse failure, a
    /// malformed file, or an actual bug, and worth a bug report if it keeps happening.
    public enum Category {
        case knownLimit
        case unexpected
    }

    public static func label(for errorText: String?) -> String {
        switch category(for: errorText) {
        case .knownLimit: return knownLimitLabel(for: errorText) ?? "Render failed"
        case .unexpected: return "Render failed"
        }
    }

    public static func category(for errorText: String?) -> Category {
        knownLimitLabel(for: errorText) != nil ? .knownLimit : .unexpected
    }

    private static func knownLimitLabel(for errorText: String?) -> String? {
        let text = errorText ?? ""
        if text.contains("uncompressed"), text.contains("safety limit") {
            return "Mesh too large to render"
        }
        if text.contains("build references"), text.contains("safety limit") {
            return "Too complex to render"
        }
        return nil
    }
}
