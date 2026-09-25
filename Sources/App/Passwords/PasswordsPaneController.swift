import AppKit

/// The "Passwords" pane of the Settings window (browser-ojh.1; see
/// SettingsWindowController, which hosts this alongside the other panes in
/// an NSTabView). Saved credentials are per-profile (PasswordStore), so this
/// pane starts with a profile picker, then lists that profile's saved
/// site/username pairs -- same profile-picker-then-table layout
/// PrivacyPaneController already established for its own per-profile list.
///
/// Never shows a password in the table itself -- only site + username.
/// Revealing the actual password requires "Reveal" plus a fresh Touch ID
/// (or passcode-fallback) check via LocalAuthentication first; there is no
/// way to see a saved password from this pane without that check succeeding.
final class PasswordsPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let profilePopup = NSPopUpButton()
    private let credentialsTableView = NSTableView()
    private let autofillCheckbox = NSButton(
        checkboxWithTitle: "Fill saved passwords automatically", target: nil, action: nil
    )

    private var selectedProfile: Profile?
    private var credentials: [SavedCredential] = []
    private var profileChangeObserver: NSObjectProtocol?

    override init() {
        super.init()
        setUpViews()
        reload()
        profileChangeObserver = NotificationCenter.default.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    /// Repopulates the profile picker from ProfileManager, preserving the
    /// current selection if it still exists, then reloads that profile's
    /// saved credentials into the table -- same pattern as
    /// PrivacyPaneController.reload().
    func reload() {
        selectedProfile = profilePopup.reloadProfiles(keeping: selectedProfile)
        loadCredentialsForSelectedProfile()
    }

    // MARK: - View setup

    private func setUpViews() {
        let margin: CGFloat = 12
        let rowGap: CGFloat = 10
        let headerHeight: CGFloat = 22
        let profileRowHeight: CGFloat = 28
        let buttonRowHeight: CGFloat = 28

        let headerLabel = NSTextField(labelWithString: "Passwords")
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.frame = NSRect(
            x: margin,
            y: view.bounds.height - margin - headerHeight,
            width: view.bounds.width - margin * 2,
            height: headerHeight
        )
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        // Bottom-up from here, mirroring the other panes' layout style.
        let revealButton = NSButton(title: "Reveal…", target: self, action: #selector(revealSelectedPassword))
        revealButton.frame = NSRect(x: margin, y: margin, width: 90, height: buttonRowHeight)
        revealButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(revealButton)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelectedCredential))
        deleteButton.frame = NSRect(x: margin + 94, y: margin, width: 70, height: buttonRowHeight)
        deleteButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(deleteButton)

        let autofillRowY = margin + buttonRowHeight + rowGap
        autofillCheckbox.frame = NSRect(x: margin, y: autofillRowY, width: view.bounds.width - margin * 2, height: 20)
        autofillCheckbox.autoresizingMask = [.width, .maxYMargin]
        autofillCheckbox.target = self
        autofillCheckbox.action = #selector(autofillPreferenceChanged)
        autofillCheckbox.state = PasswordAutofillPreference.isAutomaticFillEnabled ? .on : .off
        view.addSubview(autofillCheckbox)

        let profileRowY = autofillRowY + 20 + rowGap
        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.frame = NSRect(x: margin, y: profileRowY + 6, width: 60, height: 20)
        profileLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(profileLabel)

        profilePopup.frame = NSRect(x: margin + 64, y: profileRowY, width: 200, height: profileRowHeight)
        profilePopup.autoresizingMask = [.maxXMargin, .maxYMargin]
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        view.addSubview(profilePopup)

        // The credentials table fills the remaining space between the
        // header and the profile row.
        let scrollTop = view.bounds.height - margin - headerHeight - rowGap
        let scrollBottom = profileRowY + profileRowHeight + rowGap
        let scrollView = NSScrollView(frame: NSRect(
            x: margin, y: scrollBottom, width: view.bounds.width - margin * 2, height: max(0, scrollTop - scrollBottom)
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let siteColumn = NSTableColumn(identifier: .init("site"))
        siteColumn.title = "Site"
        siteColumn.width = 280

        let usernameColumn = NSTableColumn(identifier: .init("username"))
        usernameColumn.title = "Username"
        usernameColumn.width = 180

        credentialsTableView.addTableColumn(siteColumn)
        credentialsTableView.addTableColumn(usernameColumn)
        credentialsTableView.dataSource = self
        credentialsTableView.delegate = self
        ListAppearance.apply(to: credentialsTableView, in: scrollView)
        scrollView.documentView = credentialsTableView
        view.addSubview(scrollView)
    }

    // MARK: - Data

    private func loadCredentialsForSelectedProfile() {
        guard let profile = selectedProfile else {
            credentials = []
            credentialsTableView.reloadData()
            return
        }
        // Sorted for a stable, scannable list -- PasswordStore.allCredentials
        // makes no ordering guarantee of its own (Keychain query order isn't
        // documented as stable).
        credentials = PasswordStore.allCredentials(profileName: profile.name)
            .sorted { $0.origin == $1.origin ? $0.username < $1.username : $0.origin < $1.origin }
        credentialsTableView.reloadData()
    }

    // MARK: - Actions

    @objc private func autofillPreferenceChanged() {
        PasswordAutofillPreference.isAutomaticFillEnabled = autofillCheckbox.state == .on
    }

    @objc private func profileSelectionChanged() {
        selectedProfile = profilePopup.selectedItem?.representedObject as? Profile
        loadCredentialsForSelectedProfile()
    }

    /// Gates the one path in this whole feature that can show a saved
    /// password's actual plaintext -- a fresh LocalAuthentication check
    /// (Touch ID, falling back to the account password if Touch ID isn't
    /// available/enrolled, same as `.deviceOwnerAuthentication`'s standard
    /// behavior) must succeed first. PasswordStore.password(profileName:
    /// origin:username:) itself performs no such check -- this pane is the
    /// only caller, and this method is the only place that call happens.
    @objc private func revealSelectedPassword() {
        let row = credentialsTableView.selectedRow
        guard let profile = selectedProfile, credentials.indices.contains(row) else { return }
        let credential = credentials[row]

        SecretReveal.authenticate(
            toReveal: "password",
            reason: "reveal the saved password for \(credential.username) at \(credential.origin)"
        ) {
            guard let password = PasswordStore.password(profileName: profile.name, origin: credential.origin, username: credential.username)
            else {
                return
            }
            SecretReveal.present(password, title: "\(credential.username) at \(credential.origin)", copyButtonTitle: "Copy Password")
        }
    }

    @objc private func deleteSelectedCredential() {
        let row = credentialsTableView.selectedRow
        guard let profile = selectedProfile, credentials.indices.contains(row) else { return }
        let credential = credentials[row]

        guard NSAlert.confirmDestructive(
            message: "Delete Saved Password?",
            informativeText: "The saved password for \(credential.username) at \(credential.origin) will be removed.",
            confirmTitle: "Delete"
        ) else { return }

        PasswordStore.delete(profileName: profile.name, origin: credential.origin, username: credential.username)
        loadCredentialsForSelectedProfile()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        credentials.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard credentials.indices.contains(row), let columnIdentifier = tableColumn?.identifier else { return nil }
        let text: String
        switch columnIdentifier.rawValue {
        case "site":
            text = credentials[row].origin
        case "username":
            text = credentials[row].username
        default:
            text = ""
        }
        return ListAppearance.textCell(in: tableView, identifier: "passwordCell.\(columnIdentifier.rawValue)", text: text)
    }
}
