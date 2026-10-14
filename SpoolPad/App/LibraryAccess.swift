import Foundation
import SpoolCore

/// Persisted access to the exported library folder — the iPad-side equivalent of
/// `RootAccessManager`, but for exactly one folder, and using plain iOS security-scoped
/// bookmark conventions (no `.withSecurityScope` option — that's macOS-only) rather
/// than pulling in SpoolFS, which was never given an iOS platform: the iPad app never
/// watches folders, it only ever re-reads a snapshot someone else already wrote.
///
/// No live connection to the Mac at all — `reload()` just re-opens whatever
/// `library.sqlite` currently sits in the granted folder, matching the accepted sync
/// lag (the Mac exports periodically; this just reads the latest export each time the
/// browse view appears).
@MainActor
final class LibraryAccess: ObservableObject {
    private static let bookmarkKey = "libraryFolderBookmark"

    @Published private(set) var folderURL: URL?
    @Published private(set) var database: SQLiteSpoolDatabase?
    @Published var lastError: String?

    private var isAccessingSecurityScope = false

    init() {
        restoreFromSavedBookmark()
    }

    var isConfigured: Bool { folderURL != nil }

    /// Called with the URL from a `.fileImporter(allowedContentTypes: [.folder])` pick.
    func grantFolder(_ url: URL) {
        // A picked URL is only reachable inside a start/stop access pair, and that
        // includes creating its bookmark: without it iOS reports the folder as missing
        // (NSCocoaErrorDomain 260).
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmarkData = try url.bookmarkData()
            UserDefaults.standard.set(bookmarkData, forKey: Self.bookmarkKey)
            openLibrary(at: url)
        } catch {
            lastError = "\(error)"
        }
    }

    func reset() {
        stopAccessingIfNeeded()
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        folderURL = nil
        database = nil
    }

    func reload() {
        guard let folderURL else { return }
        openLibrary(at: folderURL)
    }

    private func restoreFromSavedBookmark() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: bookmarkData, bookmarkDataIsStale: &isStale)
            openLibrary(at: url)
            if isStale {
                let fresh = try url.bookmarkData()
                UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
            }
        } catch {
            lastError = "\(error)"
        }
    }

    /// Granting a folder and finding a readable `library.sqlite` inside it are two
    /// different states worth distinguishing — the Mac may not have exported anything
    /// there yet, which isn't an error, just a "waiting for the first export" moment
    /// the browse view can show explicitly. `folderURL` reflects the former
    /// unconditionally; `database` only when the latter actually succeeds.
    private func openLibrary(at url: URL) {
        stopAccessingIfNeeded()
        isAccessingSecurityScope = url.startAccessingSecurityScopedResource()
        folderURL = url
        requestICloudDownloads(in: url)
        let dbURL = url.appendingPathComponent("library.sqlite")
        database = FileManager.default.fileExists(atPath: dbURL.path)
            ? try? SQLiteSpoolDatabase.openReadOnly(path: dbURL.path)
            : nil
    }

    /// An iCloud Drive folder's files are often only placeholders on the iPad until
    /// something asks for them, so ask for everything in the export (the database,
    /// thumbnails and model copies). Downloads finish in the background; `reload()`
    /// picks them up. Evicted files can show up either under their real name or as a
    /// hidden `.<name>.icloud` placeholder, so both are handled.
    private func requestICloudDownloads(in folder: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in enumerator {
            let name = item.lastPathComponent
            var target = item
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                target = item.deletingLastPathComponent()
                    .appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
            }
            try? fileManager.startDownloadingUbiquitousItem(at: target)
        }
    }

    private func stopAccessingIfNeeded() {
        if isAccessingSecurityScope, let folderURL {
            folderURL.stopAccessingSecurityScopedResource()
        }
        isAccessingSecurityScope = false
    }
}
