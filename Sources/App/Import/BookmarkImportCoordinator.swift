import AppKit
import UniformTypeIdentifiers

/// Drives both bookmark-import paths (browser-ymx): File > Import
/// Bookmarks… (a standard Netscape-format HTML export -- Safari/Chrome/
/// Firefox/Edge all emit this) and File > Import Bookmarks from Safari…
/// (an opportunistic direct read of ~/Library/Safari/Bookmarks.plist,
/// which is TCC/Full-Disk-Access-protected). Both converge on the same
/// `ImportedBookmarkNode` tree (BrowserCore) and the same confirmation-
/// sheet/import flow below.
///
/// A singleton with its own explicit menu-item targets (see
/// MainMenuBuilder), not routed through AppDelegate via the responder
/// chain -- consistent with this codebase's other cross-cutting features
/// (RoutingCoordinator, ContentBlockerCoordinator), which all avoid adding
/// surface area to AppDelegate/WindowManager.
final class BookmarkImportCoordinator: NSObject {
    static let shared = BookmarkImportCoordinator()

    private override init() {
        super.init()
    }

    // MARK: - Entry points (menu actions)

    @objc func importFromFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose an exported bookmarks file (Safari: File > Export > Bookmarks…)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let html = try? String(contentsOf: url) else {
            presentAlert(
                title: "Couldn't Read File",
                message: "\(url.lastPathComponent) couldn't be read as text."
            )
            return
        }

        let nodes = NetscapeBookmarkParser.parse(html)
        presentImportConfirmation(nodes: nodes, sourceDescription: url.lastPathComponent)
    }

    @objc func importFromSafari(_ sender: Any?) {
        do {
            let nodes = try SafariBookmarksPlistParser.parse(fileURL: SafariBookmarksPlistParser.defaultFileURL())
            presentImportConfirmation(nodes: nodes, sourceDescription: "Safari")
        } catch {
            // Never silently no-op: NSDictionary(contentsOf:) returning nil
            // (both a genuine TCC/Full-Disk-Access denial and "file simply
            // doesn't exist" surface identically -- confirmed empirically,
            // see SafariBookmarksPlistParser.ReadError's doc comment) always
            // gets this same explanatory dialog, with a real path forward
            // either way.
            presentSafariReadFailureAlert()
        }
    }

    // MARK: - Confirmation + import

    private func presentImportConfirmation(nodes: [ImportedBookmarkNode], sourceDescription: String) {
        guard !nodes.isEmpty else {
            presentAlert(
                title: "No Bookmarks Found",
                message: "\(sourceDescription) didn't contain any recognizable bookmarks."
            )
            return
        }

        let counts = ImportedBookmarkNode.counts(in: nodes)
        let alert = NSAlert()
        alert.messageText = "Import Bookmarks"
        alert.informativeText = "\(counts.bookmarks) bookmark\(counts.bookmarks == 1 ? "" : "s") in "
            + "\(counts.folders) folder\(counts.folders == 1 ? "" : "s") from \(sourceDescription)."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")

        let label = NSTextField(labelWithString: "Import into:")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 0, y: 30, width: 260, height: 16)

        let destinationPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        destinationPopup.addItem(withTitle: "New folder: “Imported from Safari”")
        destinationPopup.addItem(withTitle: "Top level")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        accessory.addSubview(label)
        accessory.addSubview(destinationPopup)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = destinationPopup

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let useSubfolder = destinationPopup.indexOfSelectedItem == 0
        performImport(nodes: nodes, useSubfolder: useSubfolder)
    }

    private func performImport(nodes: [ImportedBookmarkNode], useSubfolder: Bool) {
        // The current window's profile, per browser-ymx -- falling back to
        // whatever profile exists if no window happens to be key (e.g.
        // import triggered in an unusual state); ProfileManager always has
        // at least one profile.
        guard let profile = WindowManager.shared.keyBrowserWindowController?.profile
            ?? ProfileManager.shared.profiles.first else {
            return
        }

        let stores = ProfileDataStoreManager.shared.stores(for: profile)
        let favoritesFolderId = FavoritesFolder.id(in: stores.bookmarks)

        let destinationParentId: Int64?
        if useSubfolder {
            destinationParentId = try? stores.bookmarks.addFolder(title: "Imported from Safari", parentId: nil)
        } else {
            destinationParentId = nil
        }

        let insertedURLs = BookmarkImporter.importNodes(
            nodes,
            into: stores.bookmarks,
            destinationParentId: destinationParentId,
            favoritesFolderId: favoritesFolderId
        )

        // Lazy, fire-and-forget: just warms FaviconLoader's cache so the
        // start page's Favorites tiles and the Bookmarks manager have real
        // icons sooner, without making the import wait on network calls.
        for url in insertedURLs {
            guard let host = URL(string: url)?.host else { continue }
            FaviconLoader.shared.loadFavicon(host: host, hintURL: nil, profileName: profile.name) { _ in }
        }

        presentAlert(
            title: "Import Complete",
            message: "\(insertedURLs.count) new bookmark\(insertedURLs.count == 1 ? "" : "s") imported into \u{201C}\(profile.name)\u{201D}."
        )
    }

    /// Not private -- reused as-is by SafariImportWindowController's full
    /// import flow (browser-ymx) for the identical FDA-denial case: same
    /// dialog, same System Settings deep link, same HTML-export fallback
    /// advice, regardless of which entry point hit the TCC wall.
    func presentSafariReadFailureAlert() {
        let alert = NSAlert()
        alert.messageText = "Can't Read Safari's Bookmarks Directly"
        alert.informativeText = """
        macOS protects Safari's bookmarks file. To import directly, grant Browser Full Disk Access in \
        System Settings > Privacy & Security > Full Disk Access, then try again.

        Or use Safari's own File > Export > Bookmarks…, then File > Import Bookmarks… here.
        """
        alert.addButton(withTitle: "Open Privacy Settings…")
        alert.addButton(withTitle: "OK")
        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
