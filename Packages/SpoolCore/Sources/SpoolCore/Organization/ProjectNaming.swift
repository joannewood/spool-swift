import Foundation

/// Cleanup helpers for folder-derived project names — ported test-by-test from the
/// source app's `common/text.py`. A raw downloaded-kit folder name is often full of
/// hyphens/underscores standing in for spaces, a "model_files"/"print_files"
/// container-folder suffix, a scale-ratio notation ("1_12", "125", "110th"), and a long
/// standalone numeric asset id (Thingiverse/Printables) — this cleans all of that into
/// a human-readable suggestion a user reviews before applying (see
/// `ProjectService.projectsNeedingNameCleanup`), never an automatic rewrite.
public enum ProjectNaming {
    private static let percentEncodedRegex = try! NSRegularExpression(pattern: "%[0-9A-Fa-f]{2}")
    private static let separatorRunRegex = try! NSRegularExpression(pattern: "[_-]+")
    private static let kitSuffixRegex = try! NSRegularExpression(
        pattern: #"\bmodel\s*files?\b|\bprint\s*files?\b"#, options: .caseInsensitive
    )
    private static let standaloneIdRegex = try! NSRegularExpression(pattern: #"\b\d{5,}\b"#)
    private static let whitespaceRunRegex = try! NSRegularExpression(pattern: #"\s+"#)
    // "1" + optional separator + a short number is the standard Thingiverse/Printables
    // way of writing a scale ratio in a folder name — either with a real separator
    // ("1_12", already collapsed to a space by the time this runs) or fused with none
    // at all ("125" = 1/25, "110th" = 1/10th, ordinal suffix optional). The fused form
    // only converts when the literal word "scale" immediately follows (never invented)
    // since a bare fused number is too ambiguous ("112th Anniversary", a part number).
    // `(?<!/)` guards against re-processing an already-converted ratio — a "/" can
    // never appear in a real on-disk folder name, so it only ever means this text
    // already went through a scale conversion.
    private static let scaleRegex = try! NSRegularExpression(
        pattern: #"(?<!/)\b1( ?)(\d{1,3})(st|nd|rd|th)?( scale)?\b"#, options: .caseInsensitive
    )
    private static let spaceNearParenRegex = try! NSRegularExpression(pattern: #"\(\s+|\s+\)"#)
    // Capitalizes the first letter after *any* non-alphanumeric boundary (start of
    // string, or any punctuation), not just after a plain space — matters for a name
    // that already has a parenthetical qualifier ("(ikea..." has no space inside it to
    // split on). Digits don't count as a boundary — "110th" must stay "110th".
    private static let capitalizeAfterBoundaryRegex = try! NSRegularExpression(pattern: "(^|[^a-zA-Z0-9])([a-z])")

    /// Decodes literal URL-encoding left over in a downloaded file/folder name ("%20"/
    /// "+" for space) — cosmetic only, never touches anything on disk. Decodes when the
    /// name contains a %XX escape, or a "+" with no real space already present (guards
    /// against mangling a name that intentionally has a "+" in it).
    public static func cleanName(_ name: String) -> String {
        guard !name.isEmpty else { return name }
        let fullRange = NSRange(name.startIndex..., in: name)
        let looksEncoded = percentEncodedRegex.firstMatch(in: name, range: fullRange) != nil
            || (name.contains("+") && !name.contains(" "))
        guard looksEncoded else { return name }
        let plusReplaced = name.replacingOccurrences(of: "+", with: " ")
        return plusReplaced.removingPercentEncoding ?? plusReplaced
    }

    /// A best-effort cleanup suggestion for a folder-derived project name. This is a
    /// *suggestion* a human reviews before applying, not an automatic rewrite — the
    /// heuristic will occasionally be wrong for a given name, same as any pattern-based
    /// text cleanup.
    public static func suggestCleanName(_ name: String) -> String {
        var text = cleanName(name)
        text = replaceAll(separatorRunRegex, in: text, with: " ")
        text = replaceScaleNotation(in: text)
        text = replaceAll(kitSuffixRegex, in: text, with: " ")
        text = replaceAll(standaloneIdRegex, in: text, with: " ")
        text = replaceAll(whitespaceRunRegex, in: text, with: " ").trimmingCharacters(in: .whitespaces)
        text = replaceSpaceNearParen(in: text)
        return capitalizeAfterBoundaries(in: text)
    }

    private static func replaceAll(_ regex: NSRegularExpression, in text: String, with replacement: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }

    /// Custom (not template-based) replacement — each match's fate depends on whether
    /// it had a separating space and whether a literal "scale" word followed, which
    /// `stringByReplacingMatches`' template substitution can't express.
    private static func replaceScaleNotation(in text: String) -> String {
        mapMatches(scaleRegex, in: text) { ns, match in
            let hadSpace = substring(ns, match.range(at: 1))
            let denominator = substring(ns, match.range(at: 2)) ?? ""
            let suffix = substring(ns, match.range(at: 3)) ?? ""
            let scaleWord = substring(ns, match.range(at: 4))

            if (hadSpace ?? "").isEmpty {
                // Fused form ("110th", "125") — only touch it with the "scale" anchor
                // present, and reject a "0" denominator ("10 scale" parsed as "1" + "0"
                // would give the nonsensical "1/0 scale"; a real 1/10 scale is written
                // fused as "110", not "10").
                if scaleWord == nil || denominator.hasPrefix("0") {
                    return ns.substring(with: match.range)
                }
            }
            return "1/\(denominator)\(suffix)\(scaleWord ?? "")"
        }
    }

    /// The "model files"/"print files" suffix-strip is a blind substitution — if it
    /// lands right next to a parenthesis, it leaves a stray space the whitespace-
    /// collapse step doesn't catch (that step only handles runs of 2+ spaces / the
    /// string's own outer ends). Tightens "( x" -> "(x" and "x )" -> "x)".
    private static func replaceSpaceNearParen(in text: String) -> String {
        mapMatches(spaceNearParenRegex, in: text) { ns, match in
            ns.substring(with: match.range).hasPrefix("(") ? "(" : ")"
        }
    }

    private static func capitalizeAfterBoundaries(in text: String) -> String {
        mapMatches(capitalizeAfterBoundaryRegex, in: text) { ns, match in
            let boundary = substring(ns, match.range(at: 1)) ?? ""
            let letter = substring(ns, match.range(at: 2)) ?? ""
            return boundary + letter.uppercased()
        }
    }

    private static func substring(_ ns: NSString, _ range: NSRange) -> String? {
        range.location == NSNotFound ? nil : ns.substring(with: range)
    }

    /// Shared non-overlapping left-to-right match-replace driver — every match's
    /// replacement is computed by `transform`, everything between matches passes
    /// through unchanged, mirroring how each of the Python heuristic's `re.sub` calls
    /// with a function (rather than a template string) behaves.
    private static func mapMatches(
        _ regex: NSRegularExpression, in text: String, transform: (NSString, NSTextCheckingResult) -> String
    ) -> String {
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var result = ""
        var lastEnd = 0
        regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match else { return }
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            result += transform(ns, match)
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }
}
