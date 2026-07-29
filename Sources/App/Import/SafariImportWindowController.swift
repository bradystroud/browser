import AppKit

/// The full "Import from Safari…" window (browser-ymx): profiles,
/// favourites, and history, not just the plain bookmarks-only Safari import
/// (BookmarkImportCoordinator.importFromSafari, still reachable via its own
/// menu item and left untouched -- this is a separate, bigger flow, not a
/// replacement for it). Detected Safari profiles are shown with a checkbox,
/// per-profile counts, and a destination popup (create a new Browser
/// profile, or merge into an existing one); Import writes bookmarks/
/// favourites through the existing BookmarkImporter and history through
/// HistoryStore.importVisits(_:), then shows a final summary.
///
/// Deliberately fully synchronous (scan, then import, both on the main
/// thread) -- matching every other BrowserCore-touching coordinator in this
/// app (BookmarkImportCoordinator, DownloadsWindowController, etc.), none
/// of which dispatch this kind of work to a background queue. A real
/// Safari history import is a one-time, seconds-long operation; the
/// consistency and thread-safety this buys (no concurrent access to
/// ProfileDataStoreManager's cache from two threads) is worth more than the
/// responsiveness a background queue would add.
final class SafariImportWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SafariImportWindowController()

    private struct Row {
        let profile: SafariImportProfile
        var isSelected = true
        /// 0 = create a new Browser profile named after this Safari
        /// profile; 1...N = merge into `existingProfiles[index - 1]`.
        var destinationIndex = 0
    }

    private var scanResult: SafariImportScanner.Result?
    private var rows: [Row] = []
    /// Snapshotted when the window opens so every row's destination popup
    /// stays consistent with itself for the duration of one import, even if
    /// ProfileManager changes mid-flow (e.g. a profile created by resolving
    /// an earlier row in this same import).
    private var existingProfiles: [Profile] = []

    private let tableView = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let importButton = NSButton(title: "Import", target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Import from Safari"
        window.center()
        super.init(window: window)
        window.delegate = self
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Explicit target (SafariImportWindowController.shared), not the nil-
    /// target/responder-chain pattern most of the File menu uses -- same
    /// reasoning as BookmarkImportCoordinator's own entry points (see that
    /// file's doc comment): a standalone singleton coordinator shouldn't
    /// need to add surface area to AppDelegate.
    @objc func show(_ sender: Any?) {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        runScan()
    }

    // MARK: - Scan

    private func runScan() {
        cleanUpTempDirectory()
        rows = []
        scanResult = nil
        tableView.reloadData()
        importButton.isEnabled = false
        statusLabel.stringValue = "Scanning Safari…"
        summaryLabel.stringValue = ""
        progressIndicator.startAnimation(nil)
        // Force the "Scanning…" state to actually paint before the
        // synchronous scan below blocks this same thread.
        window?.contentView?.displayIfNeeded()

        do {
            let result = try SafariImportScanner.scan()
            scanResult = result
            existingProfiles = ProfileManager.shared.profiles
            rows = result.profiles.map { Row(profile: $0) }
            tableView.reloadData()
            statusLabel.stringValue = ""
            summaryLabel.stringValue = "\(result.bookmarkCount) bookmark\(result.bookmarkCount == 1 ? "" : "s"), "
                + "\(result.favoriteCount) favourite\(result.favoriteCount == 1 ? "" : "s") -- shared across every Safari profile."
            importButton.isEnabled = !rows.isEmpty
        } catch {
            close()
            // Same dialog, same System Settings deep link, same "use
            // Safari's own export instead" fallback advice as the existing
            // bookmarks-only Safari import already shows for this exact
            // failure mode.
            BookmarkImportCoordinator.shared.presentSafariReadFailureAlert()
        }
        progressIndicator.stopAnimation(nil)
    }

    // MARK: - Import

    @objc private func performImport() {
        guard let scanResult else { return }
        let selectedRows = rows.filter { $0.isSelected }
        guard !selectedRows.isEmpty else { return }

        importButton.isEnabled = false
        statusLabel.stringValue = "Importing…"
        progressIndicator.startAnimation(nil)
        window?.contentView?.displayIfNeeded()

        let favoriteURLs = SafariImportScanner.favoriteURLs(in: scanResult.sharedBookmarks)
        var totalBookmarks = 0
        var totalFavorites = 0
        var totalHistory = 0
        var importedProfileCount = 0

        for row in selectedRows {
            let profile = resolveDestinationProfile(for: row)
            let stores = ProfileDataStoreManager.shared.stores(for: profile)
            let favoritesFolderId = FavoritesFolder.id(in: stores.bookmarks)

            let insertedURLs = BookmarkImporter.importNodes(
                scanResult.sharedBookmarks,
                into: stores.bookmarks,
                destinationParentId: nil,
                favoritesFolderId: favoritesFolderId
            )
            for url in insertedURLs {
                if favoriteURLs.contains(url) {
                    totalFavorites += 1
                } else {
                    totalBookmarks += 1
                }
            }

            if let historyPath = row.profile.historyDatabasePath,
               let visits = try? SafariHistoryReader.readVisits(fromCopiedDatabaseAt: historyPath) {
                try? stores.history.importVisits(visits.map { (url: $0.url, title: $0.title, visitTime: $0.visitTime) })
                totalHistory += visits.count
            }

            for url in insertedURLs {
                guard let host = URL(string: url)?.host else { continue }
                FaviconLoader.shared.loadFavicon(host: host, hintURL: nil, profileName: profile.name) { _ in }
            }
            importedProfileCount += 1
        }

        progressIndicator.stopAnimation(nil)
        statusLabel.stringValue = ""
        cleanUpTempDirectory()
        close()

        let alert = NSAlert()
        alert.messageText = "Import Complete"
        alert.informativeText = "Imported \(totalBookmarks) bookmark\(totalBookmarks == 1 ? "" : "s"), "
            + "\(totalFavorites) favourite\(totalFavorites == 1 ? "" : "s"), "
            + "\(totalHistory) history entr\(totalHistory == 1 ? "y" : "ies") "
            + "into \(importedProfileCount) profile\(importedProfileCount == 1 ? "" : "s")."
        alert.runModal()
    }

    private func resolveDestinationProfile(for row: Row) -> Profile {
        guard row.destinationIndex > 0 else {
            return ProfileManager.shared.createProfile(name: row.profile.displayName, colorHex: ProfileManager.shared.nextUnusedColor())
        }
        let index = row.destinationIndex - 1
        guard existingProfiles.indices.contains(index) else {
            // Shouldn't happen -- the popup is built from this exact array
            // -- but never silently import into whatever profile happens
            // to be first rather than what was actually selected.
            return ProfileManager.shared.createProfile(name: row.profile.displayName, colorHex: ProfileManager.shared.nextUnusedColor())
        }
        return existingProfiles[index]
    }

    private func cleanUpTempDirectory() {
        guard let scanResult else { return }
        try? FileManager.default.removeItem(at: scanResult.tempDirectory)
    }

    // MARK: - Views

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }
        let margin: CGFloat = 12

        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.frame = NSRect(x: margin, y: contentView.bounds.height - margin - 16, width: contentView.bounds.width - margin * 2, height: 16)
        summaryLabel.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(summaryLabel)

        let bottomRowY: CGFloat = margin
        let bottomRowHeight: CGFloat = 28

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: margin, y: bottomRowY + 6, width: 200, height: 16)
        statusLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(statusLabel)

        progressIndicator.style = .spinning
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.frame = NSRect(x: margin + 200, y: bottomRowY + 4, width: 20, height: 20)
        progressIndicator.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(progressIndicator)

        importButton.target = self
        importButton.action = #selector(performImport)
        importButton.keyEquivalent = "\r"
        importButton.frame = NSRect(x: contentView.bounds.width - margin - 100, y: bottomRowY, width: 100, height: bottomRowHeight)
        importButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(importButton)

        let scrollY = bottomRowY + bottomRowHeight + 8
        let scrollHeight = contentView.bounds.height - scrollY - margin - 24
        let scrollView = NSScrollView(frame: NSRect(x: margin, y: scrollY, width: contentView.bounds.width - margin * 2, height: scrollHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let selectColumn = NSTableColumn(identifier: .init("select"))
        selectColumn.title = ""
        selectColumn.width = 32
        let profileColumn = NSTableColumn(identifier: .init("profile"))
        profileColumn.title = "Profile"
        profileColumn.width = 320
        let destinationColumn = NSTableColumn(identifier: .init("destination"))
        destinationColumn.title = "Import Into"
        destinationColumn.width = 220

        tableView.addTableColumn(selectColumn)
        tableView.addTableColumn(profileColumn)
        tableView.addTableColumn(destinationColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 40
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch tableColumn?.identifier.rawValue {
        case "select":
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSelected(_:)))
            checkbox.tag = row
            checkbox.state = rows[row].isSelected ? .on : .off
            return checkbox
        case "profile":
            let label = NSTextField(labelWithString: "")
            let safariProfile = rows[row].profile
            label.attributedStringValue = profileLabelText(for: safariProfile)
            label.lineBreakMode = .byTruncatingTail
            return label
        case "destination":
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.tag = row
            popup.target = self
            popup.action = #selector(destinationChanged(_:))
            popup.addItem(withTitle: "Create New Profile")
            for profile in existingProfiles {
                popup.addItem(withTitle: "Merge into \u{201C}\(profile.name)\u{201D}")
            }
            popup.selectItem(at: rows[row].destinationIndex)
            return popup
        default:
            return nil
        }
    }

    private func profileLabelText(for profile: SafariImportProfile) -> NSAttributedString {
        let title = NSMutableAttributedString(string: profile.displayName + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let counts = "\(scanResult?.bookmarkCount ?? 0) bookmarks, \(scanResult?.favoriteCount ?? 0) favourites, \(profile.historyCount) history entries"
        title.append(NSAttributedString(string: counts, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
    }

    @objc private func toggleSelected(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].isSelected = sender.state == .on
    }

    @objc private func destinationChanged(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].destinationIndex = sender.indexOfSelectedItem
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        cleanUpTempDirectory()
        scanResult = nil
    }
}
