import AppKit

/// The "Passwords" pane of the Settings window (browser-ojh.1). Saved
/// credentials are per-profile (PasswordStore), so the pane has a profile
/// picker above the list of that profile's saved site/username pairs.
///
/// Never shows a password in the table itself -- only site + username.
/// Revealing the actual password requires "Reveal" plus a fresh Touch ID
/// (or passcode-fallback) check via LocalAuthentication first; there is no
/// way to see a saved password from this pane without that check succeeding.
final class PasswordsPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))

    private let profilePopup = NSPopUpButton()
    private let credentialsTableView = NSTableView()
    private let autofillCheckbox = NSButton(
        checkboxWithTitle: "Fill saved passwords automatically", target: nil, action: nil
    )
    private lazy var listButtons = SettingsTablePane.removeOnlyButtons(target: self, action: #selector(listButtonClicked))
    private lazy var revealButton = NSButton(title: "Reveal…", target: self, action: #selector(revealSelectedPassword))
    private let form = SettingsForm()

    private var selectedProfile: Profile?
    private var credentials: [SavedCredential] = []
    private var profileChangeObserver: NSObjectProtocol?
    private var passwordStoreObserver: NSObjectProtocol?

    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat {
        SettingsTablePane.preferredHeight(form: form, topMargin: SettingsForm.margin)
    }

    override init() {
        super.init()
        setUpViews()
        reload()
        profileChangeObserver = NotificationCenter.default.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        // An import posts once per saved row; coalescing into one reload on
        // the next run-loop turn keeps that to a single Keychain query.
        passwordStoreObserver = NotificationCenter.default.addObserver(
            forName: .passwordStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(self.reloadCredentials), object: nil)
            self.perform(#selector(self.reloadCredentials), with: nil, afterDelay: 0)
        }
    }

    @objc private func reloadCredentials() {
        loadCredentialsForSelectedProfile()
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
        autofillCheckbox.target = self
        autofillCheckbox.action = #selector(autofillPreferenceChanged)
        autofillCheckbox.state = PasswordAutofillPreference.isAutomaticFillEnabled ? .on : .off
        form.addRow(nil, autofillCheckbox)

        form.beginSection()
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        form.addRow("Profile:", profilePopup)

        let siteColumn = NSTableColumn(identifier: .init("site"))
        siteColumn.title = "Site"
        siteColumn.width = 340

        let usernameColumn = NSTableColumn(identifier: .init("username"))
        usernameColumn.title = "Username"
        usernameColumn.width = 220

        credentialsTableView.addTableColumn(siteColumn)
        credentialsTableView.addTableColumn(usernameColumn)
        credentialsTableView.dataSource = self
        credentialsTableView.delegate = self

        let importButton = NSButton(
            title: "Import from Another Browser…",
            target: ChromiumImportWindowController.shared,
            action: #selector(ChromiumImportWindowController.show(_:))
        )
        SettingsTablePane.install(
            in: view,
            topMargin: SettingsForm.margin,
            form: form,
            table: credentialsTableView,
            listButtons: listButtons,
            trailingButtons: [revealButton, importButton]
        )
        updateSelectionDependentControls()
    }

    // MARK: - Data

    private func loadCredentialsForSelectedProfile() {
        defer { updateSelectionDependentControls() }
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

    private func updateSelectionDependentControls() {
        let hasSelection = credentials.indices.contains(credentialsTableView.selectedRow)
        listButtons.setEnabled(hasSelection, forSegment: 0)
        revealButton.isEnabled = hasSelection
    }

    // MARK: - Actions

    @objc private func listButtonClicked() {
        deleteSelectedCredential()
    }

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
    /// credential:) itself performs no such check -- this pane is the
    /// only caller, and this method is the only place that call happens.
    @objc private func revealSelectedPassword() {
        let row = credentialsTableView.selectedRow
        guard let profile = selectedProfile, credentials.indices.contains(row) else { return }
        let credential = credentials[row]

        SecretReveal.authenticate(
            toReveal: "password",
            reason: "reveal the saved password for \(credential.username) at \(credential.origin)"
        ) {
            guard let password = PasswordStore.password(profileName: profile.name, credential: credential)
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

        PasswordStore.delete(profileName: profile.name, credential: credential)
        loadCredentialsForSelectedProfile()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        credentials.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionDependentControls()
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
