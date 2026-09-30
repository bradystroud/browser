import AppKit
import UniformTypeIdentifiers

/// The full "Import from Safari…" window (browser-ymx): profiles,
/// favourites, history, and passwords, not just the plain bookmarks-only
/// Safari import (BookmarkImportCoordinator.importFromSafari, still
/// reachable via its own menu item and left untouched -- this is a
/// separate, bigger flow, not a replacement for it). Detected Safari
/// profiles are shown with a checkbox, per-profile counts, and a
/// destination popup (create a new Browser profile, or merge into an
/// existing one); Import writes bookmarks/favourites through the existing
/// BookmarkImporter and history through HistoryStore.importVisits(_:), then
/// shows a final summary. Passwords are a separate section below the
/// table: a single CSV file (Chrome or Safari export) chosen once, not tied
/// to any detected Safari profile row -- see passwordEntries' own doc
/// comment for why, and docs/ai-tasks/password-import-notes.md for the full
/// investigation (including what's deliberately NOT built here).
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

    /// Passwords are CSV-only, for both Chrome and Safari (browser-ymx) --
    /// neither's saved passwords can be read directly the way Safari's
    /// bookmarks/history can: Chrome's are AES-encrypted with a key in a
    /// Keychain item another app owns (see docs/ai-tasks/
    /// password-import-notes.md for why that's investigated but
    /// deliberately not built here), and Safari's are further restricted
    /// by keychain ACLs to Safari/AuthenticationServices only, with no
    /// programmatic path at all. So this is a single, independent CSV
    /// chosen once -- not tied to any detected Safari profile row above.
    private var passwordEntries: [PasswordCSVEntry] = []
    private var chosenPasswordFileURL: URL?
    /// Same 0-is-create-new/1...N-is-merge-into-existingProfiles[index-1]
    /// convention as Row.destinationIndex above, but independent of it --
    /// defaults to merging into the first existing profile (index 1) when
    /// one exists, since a password CSV isn't "a new identity" the way a
    /// detected Safari profile is.
    private var passwordDestinationIndex = 0

    private let tableView = NSTableView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let importButton = NSButton(title: "Import", target: nil, action: nil)

    private let passwordsSectionLabel = NSTextField(labelWithString: "Passwords")
    private let passwordsCaptionLabel = NSTextField(wrappingLabelWithString: "")
    private let choosePasswordFileButton = NSButton(title: "Choose CSV File…", target: nil, action: nil)
    private let passwordFileStatusLabel = NSTextField(labelWithString: "No file chosen")
    private let passwordDestinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let overwritePasswordsCheckbox = NSButton(checkboxWithTitle: "Overwrite existing entries", target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
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
        AppActivation.activate()
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

        // Refreshed before the scan, and before either branch below calls
        // tableView.reloadData()/rebuildPasswordDestinationPopup() -- both
        // read `existingProfiles` synchronously while rebuilding their
        // cell/menu content, so this must already hold this run's value
        // rather than being set afterward (an earlier version of this
        // function set it after reloadData() had already fired, which
        // rendered the popups with a stale list from the previous run).
        existingProfiles = ProfileManager.shared.profiles
        rebuildPasswordDestinationPopup()

        do {
            let result = try SafariImportScanner.scan()
            scanResult = result
            rows = result.profiles.map { Row(profile: $0) }
            tableView.reloadData()
            summaryLabel.stringValue = "Each profile brings its own Safari Favorites folder. Safari Default also brings every bookmark that is in no profile\u{2019}s Favorites."
        } catch {
            // Deliberately does NOT close the window (unlike the plain
            // bookmarks-only Safari import, which has nothing else to
            // offer once this fails): the Passwords section below needs
            // no Safari file access at all -- it's a manually-chosen CSV
            // -- so an FDA denial shouldn't take that path down with it.
            // Same dialog, same System Settings deep link, same "use
            // Safari's own export instead" fallback advice as the plain
            // bookmarks-only import shows for this exact failure mode.
            rows = []
            summaryLabel.stringValue = "Couldn't read Safari's bookmarks/history directly -- see the dialog for how to fix that. Passwords can still be imported below."
            BookmarkImportCoordinator.shared.presentSafariReadFailureAlert()
        }
        statusLabel.stringValue = ""
        updateImportButtonEnabled()
        progressIndicator.stopAnimation(nil)
    }

    private func updateImportButtonEnabled() {
        importButton.isEnabled = rows.contains { $0.isSelected } || !passwordEntries.isEmpty
    }

    // MARK: - Import

    @objc private func performImport() {
        let selectedRows = rows.filter { $0.isSelected }
        guard !selectedRows.isEmpty || !passwordEntries.isEmpty else { return }

        importButton.isEnabled = false
        statusLabel.stringValue = "Importing…"
        progressIndicator.startAnimation(nil)
        window?.contentView?.displayIfNeeded()

        // nil only if the Safari scan itself failed (FDA denied) -- in
        // that case selectedRows is necessarily empty (see runScan's own
        // catch block), so this loop just doesn't run; passwords below
        // are entirely independent of this succeeding.
        var totalBookmarks = 0
        var totalFavorites = 0
        var totalHistory = 0
        var importedProfileCount = 0

        for row in selectedRows {
            let favoriteURLs = SafariImportScanner.favoriteURLs(in: row.profile.bookmarks)
            let profile = resolveDestinationProfile(for: row)
            let stores = ProfileDataStoreManager.shared.stores(for: profile)
            let favoritesFolderId = FavoritesFolder.id(in: stores.bookmarks)

            let insertedURLs = BookmarkImporter.importNodes(
                row.profile.bookmarks,
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
                // One transaction: it either writes every visit or none.
                if let added = try? stores.history.importVisits(visits.map { (url: $0.url, title: $0.title, visitTime: $0.visitTime) }) {
                    totalHistory += added
                }
            }

            for url in insertedURLs {
                guard let host = URL(string: url)?.host else { continue }
                FaviconLoader.shared.loadFavicon(host: host, hintURL: nil, profileId: profile.id) { _ in }
            }
            importedProfileCount += 1
        }

        // Passwords: a single independent CSV, not tied to any Safari
        // profile row above -- see passwordEntries' own doc comment.
        var totalPasswords = 0
        let passwordEntryCount = passwordEntries.count
        let passwordFile = chosenPasswordFileURL
        if !passwordEntries.isEmpty {
            let destination = resolvePasswordDestinationProfile()
            let result = PasswordImportCoordinator.importEntries(
                passwordEntries,
                into: destination,
                overwriteExisting: overwritePasswordsCheckbox.state == .on
            )
            totalPasswords = result.importedCount
            if importedProfileCount == 0 { importedProfileCount = 1 }
            // SECURITY: drop the parsed plaintext entries the moment this
            // pass over them is done -- see this property's own doc
            // comment and PasswordImportCoordinator's for the same rule.
            passwordEntries = []
        }

        progressIndicator.stopAnimation(nil)
        statusLabel.stringValue = ""
        cleanUpTempDirectory()
        close()

        var summary = "Imported \(totalBookmarks) bookmark\(totalBookmarks == 1 ? "" : "s"), "
            + "\(totalFavorites) favourite\(totalFavorites == 1 ? "" : "s"), "
            + "\(totalHistory) history entr\(totalHistory == 1 ? "y" : "ies")"
        if passwordFile != nil {
            summary += ", \(totalPasswords) password\(totalPasswords == 1 ? "" : "s")"
        }
        summary += " into \(importedProfileCount) profile\(importedProfileCount == 1 ? "" : "s")."

        // The plaintext file is the only remaining copy of any entry that
        // was not imported, so deleting it is only offered once nothing in
        // it would be lost.
        let skippedPasswords = passwordEntryCount - totalPasswords
        let offerToDeletePasswordFile = passwordFile != nil && passwordEntryCount > 0 && skippedPasswords == 0
        if let passwordFile, !offerToDeletePasswordFile {
            summary += " \(skippedPasswords) password\(skippedPasswords == 1 ? " was" : "s were") not imported "
                + "(already saved, missing a site or username, or the Keychain refused them), "
                + "so \(passwordFile.lastPathComponent) has been kept."
        }

        let alert = NSAlert()
        alert.messageText = "Import Complete"
        alert.informativeText = summary
        alert.runModal()

        if offerToDeletePasswordFile, let passwordFile {
            offerToDeletePasswordCSV(at: passwordFile)
        }
    }

    /// Brady's own explicit requirement: after a successful password
    /// import, offer to remove the plaintext CSV, defaulting to yes, and
    /// regardless of the answer, the file has already been shown as
    /// plaintext in this window's own caption before the user ever chose
    /// it (see passwordsCaptionLabel's text in setUpViews()).
    private func offerToDeletePasswordCSV(at url: URL) {
        let alert = NSAlert()
        alert.messageText = "Delete the Password File?"
        alert.informativeText = "\(url.lastPathComponent) contains your passwords in plain text. "
            + "Now that they're imported, it's safer to delete it."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Keep It")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        PasswordImportCoordinator.securelyDelete(fileAt: url)
    }

    private func resolvePasswordDestinationProfile() -> Profile {
        guard passwordDestinationIndex > 0 else {
            return ProfileManager.shared.createProfile(name: "Imported Passwords", colorHex: ProfileManager.shared.nextUnusedColor())
        }
        let index = passwordDestinationIndex - 1
        guard existingProfiles.indices.contains(index) else {
            return ProfileManager.shared.profiles.first ?? ProfileManager.shared.createProfile(name: "Imported Passwords", colorHex: ProfileManager.shared.nextUnusedColor())
        }
        return existingProfiles[index]
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

        // Passwords section -- a fixed-height strip directly above the
        // bottom bar, below the Safari-profiles table. Independent of that
        // table: see passwordEntries' own doc comment for why (CSV-only,
        // not tied to any detected Safari profile).
        let passwordsSectionY = bottomRowY + bottomRowHeight + 8
        let passwordsSectionHeight: CGFloat = 140
        let contentWidth = contentView.bounds.width - margin * 2

        passwordsSectionLabel.font = .boldSystemFont(ofSize: 12)
        passwordsSectionLabel.frame = NSRect(x: margin, y: passwordsSectionY + passwordsSectionHeight - 18, width: contentWidth, height: 16)
        passwordsSectionLabel.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(passwordsSectionLabel)

        passwordsCaptionLabel.font = .systemFont(ofSize: 11)
        passwordsCaptionLabel.textColor = .secondaryLabelColor
        passwordsCaptionLabel.stringValue = "Safari and Chrome both protect saved passwords from direct reading -- neither is included in the scan above. "
            + "Export a CSV (Safari: Passwords app → ⋯ → Export All Passwords…; Chrome: chrome://password-manager/settings → Export passwords), then choose it here. "
            + "The exported file contains your passwords in plain text."
        passwordsCaptionLabel.frame = NSRect(x: margin, y: passwordsSectionY + 62, width: contentWidth, height: 44)
        passwordsCaptionLabel.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(passwordsCaptionLabel)

        choosePasswordFileButton.target = self
        choosePasswordFileButton.action = #selector(choosePasswordFile)
        choosePasswordFileButton.frame = NSRect(x: margin, y: passwordsSectionY + 32, width: 150, height: 24)
        choosePasswordFileButton.autoresizingMask = [.maxYMargin]
        contentView.addSubview(choosePasswordFileButton)

        passwordFileStatusLabel.font = .systemFont(ofSize: 11)
        passwordFileStatusLabel.textColor = .secondaryLabelColor
        passwordFileStatusLabel.lineBreakMode = .byTruncatingMiddle
        passwordFileStatusLabel.frame = NSRect(x: margin + 160, y: passwordsSectionY + 36, width: contentWidth - 160, height: 16)
        passwordFileStatusLabel.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(passwordFileStatusLabel)

        passwordDestinationPopup.target = self
        passwordDestinationPopup.action = #selector(passwordDestinationChanged(_:))
        passwordDestinationPopup.frame = NSRect(x: margin, y: passwordsSectionY, width: 220, height: 24)
        passwordDestinationPopup.autoresizingMask = [.maxYMargin]
        contentView.addSubview(passwordDestinationPopup)

        overwritePasswordsCheckbox.frame = NSRect(x: margin + 230, y: passwordsSectionY + 4, width: contentWidth - 230, height: 18)
        overwritePasswordsCheckbox.autoresizingMask = [.width, .maxYMargin]
        contentView.addSubview(overwritePasswordsCheckbox)

        let scrollY = passwordsSectionY + passwordsSectionHeight + 8
        let scrollHeight = contentView.bounds.height - scrollY - margin - 24
        let scrollView = NSScrollView(frame: NSRect(x: margin, y: scrollY, width: contentWidth, height: scrollHeight))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

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
        ListAppearance.apply(to: tableView, in: scrollView, rowHeight: 40)
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
    }

    private func rebuildPasswordDestinationPopup() {
        passwordDestinationPopup.removeAllItems()
        passwordDestinationPopup.addItem(withTitle: "Create New Profile")
        for profile in existingProfiles {
            passwordDestinationPopup.addItem(withTitle: "Merge into \u{201C}\(profile.name)\u{201D}")
        }
        // Default to the first existing profile rather than "create new"
        // when one exists -- see passwordDestinationIndex's own doc
        // comment for why.
        passwordDestinationIndex = existingProfiles.isEmpty ? 0 : 1
        passwordDestinationPopup.selectItem(at: passwordDestinationIndex)
    }

    @objc private func passwordDestinationChanged(_ sender: NSPopUpButton) {
        passwordDestinationIndex = sender.indexOfSelectedItem
    }

    @objc private func choosePasswordFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose a password CSV export (Safari's Passwords app, or Chrome's chrome://password-manager/settings)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let text = try? String(contentsOf: url) else {
            passwordFileStatusLabel.stringValue = "Couldn't read \(url.lastPathComponent) as text."
            return
        }
        do {
            let entries = try PasswordCSVParser.parse(csv: text)
            guard !entries.isEmpty else {
                passwordFileStatusLabel.stringValue = "\(url.lastPathComponent) — no passwords found."
                passwordEntries = []
                chosenPasswordFileURL = nil
                updateImportButtonEnabled()
                return
            }
            passwordEntries = entries
            chosenPasswordFileURL = url
            passwordFileStatusLabel.stringValue = "\(url.lastPathComponent) — \(entries.count) password\(entries.count == 1 ? "" : "s") found."
        } catch {
            passwordFileStatusLabel.stringValue = "\(url.lastPathComponent) doesn't look like a recognized password export."
            passwordEntries = []
            chosenPasswordFileURL = nil
        }
        updateImportButtonEnabled()
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
        let counts = "\(profile.bookmarkCount) bookmarks, \(profile.favoriteCount) favourites, \(profile.historyCount) history entries"
        title.append(NSAttributedString(string: counts, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
    }

    @objc private func toggleSelected(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].isSelected = sender.state == .on
        updateImportButtonEnabled()
    }

    @objc private func destinationChanged(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].destinationIndex = sender.indexOfSelectedItem
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        cleanUpTempDirectory()
        scanResult = nil
        // SECURITY: don't let parsed plaintext passwords linger in memory
        // once the window most recently offered to import them is gone --
        // same "hold only as long as needed" rule as everywhere else this
        // feature touches a password value.
        passwordEntries = []
        chosenPasswordFileURL = nil
        passwordFileStatusLabel.stringValue = "No file chosen"
    }
}
