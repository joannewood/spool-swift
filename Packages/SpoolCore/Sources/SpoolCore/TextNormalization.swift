import Foundation

/// Treats hyphens, underscores, and spaces as interchangeable — so searching "cake
/// stand" matches a file literally named `cake_stand.stl`. Exposed both as a Swift
/// function (for building search clauses / porting the relationship/project-naming
/// heuristics) and registered as a SQLite scalar function `normalize(text)` (see
/// `SpoolDatabase`) so trigger-maintained shadow columns and ad hoc queries agree.
public enum SpoolTextNormalization {
    public static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = false
        for scalar in text.lowercased().unicodeScalars {
            let isSeparator = scalar == "-" || scalar == "_" || scalar == " "
            if isSeparator {
                if !lastWasSpace {
                    result.unicodeScalars.append(" ")
                    lastWasSpace = true
                }
            } else {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
