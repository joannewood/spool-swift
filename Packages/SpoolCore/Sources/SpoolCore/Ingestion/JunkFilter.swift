/// Filesystem clutter that must never become a tracked row — mirrors the source app's
/// `is_ignorable_junk`, including the AppleDouble (`._*`) fix that had to be added
/// after real `._Hammer handle.stl` rows showed up alongside the real file (macOS
/// writes these resource-fork shadow files onto non-native volumes/network shares).
public enum JunkFilter {
    private static let exactNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]

    public static func isIgnorable(_ filename: String) -> Bool {
        if exactNames.contains(filename) { return true }
        if filename.hasPrefix("._") { return true }
        return false
    }
}
