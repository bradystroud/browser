import AppKit

/// File > Import from Another Browser…: passwords, bookmarks and history
/// from one profile of a Chromium-family browser (Chrome, Arc, Brave, Edge,
/// Dia, Vivaldi, Opera, Helium) into one of this app's profiles.
///
/// Discovery reads only directory listings and `Local State`; nothing is
/// read from the keychain until the user has checked Passwords, pressed
/// Import and confirmed the alert that explains the macOS keychain prompt.
/// Synchronous on the main thread, like SafariImportWindowController, for
/// the same reason: BrowserCore's stores are touched from the main thread
/// everywhere else.
///
/// SECURITY: never log a password or key. Decrypted entries live only for
/// the duration of `importPasswords`, the derived key is wiped as soon as
/// the last row is decrypted, and the copied `Login Data` is deleted before
/// that function returns.
final class ChromiumImportWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ChromiumImportWindowController()

    private var browsers: [(browser: ChromiumBrowser, profiles: [ChromiumProfile])] = []
    /// Snapshotted when the window opens so the destination popup's indices
    /// stay stable for the length of one import.
    private var existingProfiles: [Profile] = []

    private let browserPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let passwordsCheckbox = NSButton(checkboxWithTitle: "Passwords", target: nil, action: nil)
    private let bookmarksCheckbox = NSButton(checkboxWithTitle: "Bookmarks", target: nil, action: nil)
    private let historyCheckbox = NSButton(checkboxWithTitle: "History", target: nil, action: nil)
    private let overwriteCheckbox = NSButton(checkboxWithTitle: "Replace passwords already saved here", target: nil, action: nil)
    private let destinationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let keychainNoteLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let importButton = NSButton(title: "Import", target: nil, action: nil)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Import from Another Browser"
        window.center()
        super.init(window: window)
        window.delegate = self
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc func show(_ sender: Any?) {
        browsers = ChromiumBrowserDiscovery.installedBrowsers()
        existingProfiles = ProfileManager.shared.profiles
        rebuildBrowserPopup()
        rebuildDestinationPopup()
        statusLabel.stringValue = browsers.isEmpty
            ? "No Chromium-based browsers with data to import were found on this Mac."
            : ""
        window?.makeKeyAndOrderFront(nil)
        AppActivation.activate()
    }

    // MARK: - Selection

    private var selectedBrowser: (browser: ChromiumBrowser, profiles: [ChromiumProfile])? {
        let index = browserPopup.indexOfSelectedItem
        return browsers.indices.contains(index) ? browsers[index] : nil
    }

    private var selectedProfile: ChromiumProfile? {
        guard let profiles = selectedBrowser?.profiles else { return nil }
        let index = profilePopup.indexOfSelectedItem
        return profiles.indices.contains(index) ? profiles[index] : nil
    }

    private func rebuildBrowserPopup() {
        browserPopup.removeAllItems()
        for entry in browsers {
            browserPopup.addItem(withTitle: entry.browser.name)
        }
        browserPopup.isEnabled = !browsers.isEmpty
        rebuildProfilePopup()
    }

    private func rebuildProfilePopup() {
        profilePopup.removeAllItems()
        for profile in selectedBrowser?.profiles ?? [] {
            profilePopup.addItem(withTitle: profile.displayName)
        }
        profilePopup.isEnabled = (selectedBrowser?.profiles.count ?? 0) > 1
        refreshForSelectedProfile()
    }

    private func rebuildDestinationPopup() {
        destinationPopup.removeAllItems()
        destinationPopup.addItem(withTitle: "Create New Profile")
        for profile in existingProfiles {
            destinationPopup.addItem(withTitle: "Merge into \u{201C}\(profile.name)\u{201D}")
        }
        destinationPopup.selectItem(at: existingProfiles.isEmpty ? 0 : 1)
    }

    /// Each checkbox is enabled, and checked by default, only when the
    /// selected profile actually has that kind of data.
    private func refreshForSelectedProfile() {
        let profile = selectedProfile
        for (checkbox, available) in [
            (passwordsCheckbox, profile?.hasLoginData ?? false),
            (bookmarksCheckbox, profile?.hasBookmarks ?? false),
            (historyCheckbox, profile?.hasHistory ?? false),
        ] {
            checkbox.isEnabled = available
            checkbox.state = available ? .on : .off
        }
        refreshControls()
    }

    private func refreshControls() {
        let wantsPasswords = passwordsCheckbox.state == .on
        overwriteCheckbox.isEnabled = wantsPasswords
        if let browser = selectedBrowser?.browser, wantsPasswords {
            let item = browser.keychainItems.first?.service ?? "\(browser.name) Safe Storage"
            keychainNoteLabel.stringValue = "To read \(browser.name)\u{2019}s passwords, macOS will ask whether Browser may use "
                + "\u{201C}\(item)\u{201D} from your keychain. Enter your Mac login password and choose Allow. "
                + "Nothing is read until you do, and the key is discarded as soon as the import finishes."
        } else {
            keychainNoteLabel.stringValue = ""
        }
        importButton.isEnabled = selectedProfile != nil
            && [passwordsCheckbox, bookmarksCheckbox, historyCheckbox].contains { $0.state == .on }
    }

    @objc private func browserChanged(_ sender: Any?) {
        rebuildProfilePopup()
    }

    @objc private func profileChanged(_ sender: Any?) {
        refreshForSelectedProfile()
    }

    @objc private func checkboxChanged(_ sender: Any?) {
        refreshControls()
    }

    // MARK: - Import

    @objc private func performImport(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        let browser = profile.browser
        let wantsPasswords = passwordsCheckbox.state == .on
        let wantsBookmarks = bookmarksCheckbox.state == .on
        let wantsHistory = historyCheckbox.state == .on

        // The popup was filled when the window opened; the profile it names
        // may since have been renamed (passwords are keyed by name) or
        // deleted (its directory would be recreated), so it is looked up
        // again by id before anything is read.
        guard let target = currentDestinationChoice() else {
            let alert = NSAlert()
            alert.messageText = "That Profile No Longer Exists"
            alert.informativeText = "Choose another profile to import into."
            alert.runModal()
            existingProfiles = ProfileManager.shared.profiles
            rebuildDestinationPopup()
            return
        }

        if wantsPasswords, !confirmKeychainPrompt(for: browser) { return }

        importButton.isEnabled = false
        statusLabel.stringValue = "Importing…"
        progressIndicator.startAnimation(nil)
        window?.contentView?.displayIfNeeded()

        let destination = target ?? createDestinationProfile(for: profile)
        var lines: [String] = []

        if wantsPasswords {
            lines.append(importPasswords(from: profile, into: destination))
        }
        if wantsBookmarks {
            lines.append(importBookmarks(from: profile, into: destination))
        }
        if wantsHistory {
            lines.append(importHistory(from: profile, into: destination))
        }

        progressIndicator.stopAnimation(nil)
        statusLabel.stringValue = ""
        refreshControls()
        close()

        let alert = NSAlert()
        alert.messageText = "Import from \(browser.name) Complete"
        alert.informativeText = "Into \u{201C}\(destination.name)\u{201D}:\n\n" + lines.joined(separator: "\n")
        alert.runModal()
    }

    private func confirmKeychainPrompt(for browser: ChromiumBrowser) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Allow Access to \(browser.name)\u{2019}s Passwords?"
        alert.informativeText = "\(browser.name) encrypts its saved passwords with a key kept in your keychain. "
            + "macOS will now ask whether Browser may use that key. Enter your Mac login password and choose Allow "
            + "(\u{201C}Always Allow\u{201D} is not needed). If you choose Deny, bookmarks and history are still imported."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func importPasswords(from source: ChromiumProfile, into destination: Profile) -> String {
        let key: ChromiumSafeStorageKey
        switch ChromiumSafeStorageKeychain.key(for: source.browser) {
        case .key(let found):
            key = found
        case .denied:
            return "Passwords: not imported \u{2014} keychain access was denied."
        case .notFound:
            return "Passwords: not imported \u{2014} \(source.browser.name)\u{2019}s keychain key wasn\u{2019}t found."
        case .failed(let status):
            return "Passwords: not imported \u{2014} the keychain returned error \(status)."
        }
        defer { key.wipe() }

        let rows: [ChromiumLoginRow]
        do {
            rows = try ChromiumProfileReader.withCopiedDatabase(at: source.loginDataURL) {
                try ChromiumProfileReader.readLogins(fromCopiedDatabaseAt: $0)
            }
        } catch {
            return "Passwords: not imported \u{2014} \(source.browser.name)\u{2019}s password file couldn\u{2019}t be read."
        }

        let extraction = ChromiumPasswordExtractor.extract(rows: rows, key: key)
        key.wipe()
        let result = PasswordImportCoordinator.importEntries(
            extraction.entries,
            into: destination,
            overwriteExisting: overwriteCheckbox.state == .on
        )

        var parts = ["\(result.importedCount) imported"]
        if result.skippedAsDuplicateCount > 0 {
            parts.append("\(result.skippedAsDuplicateCount) already saved")
        }
        let unusable = result.unusableCount + extraction.emptyCount
        if unusable > 0 {
            parts.append("\(unusable) skipped (no web address, username or password)")
        }
        let failed = extraction.undecryptableCount + result.failedCount
        if failed > 0 {
            parts.append("\(failed) couldn\u{2019}t be read or saved")
        }
        return "Passwords: " + parts.joined(separator: ", ") + "."
    }

    private func importBookmarks(from source: ChromiumProfile, into destination: Profile) -> String {
        guard let data = try? Data(contentsOf: source.bookmarksURL),
              let nodes = try? ChromiumProfileReader.parseBookmarks(data: data)
        else {
            return "Bookmarks: not imported \u{2014} the bookmarks file couldn\u{2019}t be read."
        }
        let stores = ProfileDataStoreManager.shared.stores(for: destination)
        let inserted = BookmarkImporter.importNodes(
            nodes,
            into: stores.bookmarks,
            destinationParentId: nil,
            favoritesFolderId: FavoritesFolder.id(in: stores.bookmarks)
        )
        for host in Set(inserted.compactMap { URL(string: $0)?.host }) {
            FaviconLoader.shared.loadFavicon(host: host, hintURL: nil, profileId: destination.id) { _ in }
        }
        return "Bookmarks: \(inserted.count) imported."
    }

    private func importHistory(from source: ChromiumProfile, into destination: Profile) -> String {
        let visits: [ChromiumHistoryVisit]
        do {
            visits = try ChromiumProfileReader.withCopiedDatabase(at: source.historyURL) {
                try ChromiumProfileReader.readVisits(fromCopiedDatabaseAt: $0)
            }
        } catch {
            return "History: not imported \u{2014} the history file couldn\u{2019}t be read."
        }
        let stores = ProfileDataStoreManager.shared.stores(for: destination)
        // One transaction: it either writes every visit or none.
        guard let added = try? stores.history.importVisits(visits.map { (url: $0.url, title: $0.title, visitTime: $0.visitTime) }) else {
            return "History: not imported \u{2014} it couldn\u{2019}t be saved."
        }
        let alreadyThere = visits.count - added
        return "History: \(added) visit\(added == 1 ? "" : "s") imported"
            + (alreadyThere > 0 ? ", \(alreadyThere) already there." : ".")
    }

    /// `.some(nil)` means "Create New Profile"; `nil` means the chosen
    /// existing profile is gone.
    private func currentDestinationChoice() -> Profile?? {
        let index = destinationPopup.indexOfSelectedItem - 1
        guard existingProfiles.indices.contains(index) else { return .some(nil) }
        let id = existingProfiles[index].id
        guard let current = ProfileManager.shared.profiles.first(where: { $0.id == id }) else { return nil }
        return .some(current)
    }

    private func createDestinationProfile(for source: ChromiumProfile) -> Profile {
        let multipleProfiles = (selectedBrowser?.profiles.count ?? 0) > 1
        let name = multipleProfiles ? "\(source.browser.name) \u{2013} \(source.displayName)" : source.browser.name
        return ProfileManager.shared.createProfile(name: name, colorHex: ProfileManager.shared.nextUnusedColor())
    }

    // MARK: - Views

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }
        let margin: CGFloat = 20
        let labelWidth: CGFloat = 90
        let controlX = margin + labelWidth + 8
        let controlWidth: CGFloat = 260
        var y = contentView.bounds.height - margin - 26

        func addRow(_ title: String, _ control: NSView) {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.frame = NSRect(x: margin, y: y + 4, width: labelWidth, height: 17)
            contentView.addSubview(label)
            control.frame = NSRect(x: controlX, y: y, width: controlWidth, height: 26)
            contentView.addSubview(control)
            y -= 34
        }

        browserPopup.target = self
        browserPopup.action = #selector(browserChanged(_:))
        addRow("Browser:", browserPopup)

        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        addRow("Profile:", profilePopup)

        let importLabel = NSTextField(labelWithString: "Import:")
        importLabel.alignment = .right
        importLabel.frame = NSRect(x: margin, y: y + 4, width: labelWidth, height: 17)
        contentView.addSubview(importLabel)
        for checkbox in [passwordsCheckbox, bookmarksCheckbox, historyCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(checkboxChanged(_:))
            checkbox.frame = NSRect(x: controlX, y: y + 3, width: 300, height: 18)
            contentView.addSubview(checkbox)
            y -= 22
        }
        overwriteCheckbox.frame = NSRect(x: controlX + 20, y: y + 3, width: 300, height: 18)
        overwriteCheckbox.controlSize = .small
        overwriteCheckbox.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        contentView.addSubview(overwriteCheckbox)
        y -= 34

        destinationPopup.target = self
        addRow("Into:", destinationPopup)

        keychainNoteLabel.font = .systemFont(ofSize: 11)
        keychainNoteLabel.textColor = .secondaryLabelColor
        keychainNoteLabel.frame = NSRect(x: margin, y: 52, width: contentView.bounds.width - margin * 2, height: y + 26 - 52 - 4)
        contentView.addSubview(keychainNoteLabel)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: margin, y: 22, width: 340, height: 16)
        contentView.addSubview(statusLabel)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.frame = NSRect(x: contentView.bounds.width - margin - 100 - 28, y: 20, width: 18, height: 18)
        contentView.addSubview(progressIndicator)

        importButton.target = self
        importButton.action = #selector(performImport(_:))
        importButton.keyEquivalent = "\r"
        importButton.bezelStyle = .rounded
        importButton.frame = NSRect(x: contentView.bounds.width - margin - 100, y: 14, width: 100, height: 30)
        contentView.addSubview(importButton)
    }
}
