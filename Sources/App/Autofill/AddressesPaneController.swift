import AppKit

/// The "Addresses" section of the Autofill Settings pane (browser-ojh.2) --
/// same profile-picker-then-table layout as PasswordsPaneController/
/// CardsPaneController. Not secret data, so unlike those two, this pane
/// shows the address directly in the table -- no Touch-ID-gated reveal --
/// and additionally supports adding/editing (AddressFormSheetController),
/// since there's no page-submit flow guaranteed to ever populate this list
/// otherwise (a user might want to add their own address without first
/// filling out some site's checkout form).
final class AddressesPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))

    private let profilePopup = NSPopUpButton()
    private let addressesTableView = NSTableView()
    private lazy var listButtons = SettingsListButtons(target: self, action: #selector(listButtonClicked))
    private lazy var editButton = NSButton(title: "Edit…", target: self, action: #selector(editSelectedAddress))
    private let form = SettingsForm()

    private var selectedProfile: Profile?
    private var addresses: [StoredAddress] = []
    private var profileChangeObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?

    private let meCardCheckbox = NSButton(checkboxWithTitle: "Fill from my contact card", target: nil, action: nil)
    private let meCardStatusLabel = SettingsForm.footnote()
    private let meCardActionButton = NSButton(title: "", target: nil, action: nil)

    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat {
        SettingsTablePane.preferredHeight(form: form, topMargin: CardsPaneController.topMargin)
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
        // Coming back from System Settings is how access usually changes.
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateMeCardRow()
        }
    }

    func reload() {
        selectedProfile = profilePopup.reloadProfiles(keeping: selectedProfile)
        loadAddressesForSelectedProfile()
        updateMeCardRow()
    }

    // MARK: - View setup

    private func setUpViews() {
        // The contact card applies to every profile, so it sits above the
        // profile picker rather than beside the per-profile list.
        meCardCheckbox.target = self
        meCardCheckbox.action = #selector(meCardPreferenceChanged)
        meCardActionButton.bezelStyle = .push
        meCardActionButton.controlSize = .small
        meCardActionButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        meCardActionButton.target = self
        meCardActionButton.action = #selector(meCardActionTapped)
        form.addRow(nil, meCardCheckbox, meCardActionButton)
        form.addFootnote(meCardStatusLabel, indented: true)

        form.beginSection()
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        form.addRow("Profile:", profilePopup)

        let nameColumn = NSTableColumn(identifier: .init("fullName"))
        nameColumn.title = "Name"
        nameColumn.width = 200

        let addressColumn = NSTableColumn(identifier: .init("address"))
        addressColumn.title = "Address"
        addressColumn.width = 360

        addressesTableView.addTableColumn(nameColumn)
        addressesTableView.addTableColumn(addressColumn)
        addressesTableView.dataSource = self
        addressesTableView.delegate = self
        addressesTableView.target = self
        addressesTableView.doubleAction = #selector(editSelectedAddress)

        SettingsTablePane.install(
            in: view,
            topMargin: CardsPaneController.topMargin,
            form: form,
            table: addressesTableView,
            listButtons: listButtons,
            trailingButtons: [editButton]
        )
        updateSelectionDependentControls()
    }

    // MARK: - Data

    private func loadAddressesForSelectedProfile() {
        defer { updateSelectionDependentControls() }
        guard let profile = selectedProfile else {
            addresses = []
            addressesTableView.reloadData()
            return
        }
        addresses = AddressStoreManager.shared.store(forProfileId: profile.id).all()
            .sorted { $0.fullName == $1.fullName ? $0.streetAddress < $1.streetAddress : $0.fullName < $1.fullName }
        addressesTableView.reloadData()
    }

    private func updateSelectionDependentControls() {
        let hasSelection = addresses.indices.contains(addressesTableView.selectedRow)
        listButtons.canRemove = hasSelection
        editButton.isEnabled = hasSelection
    }

    // MARK: - Contact card

    /// The switch, a one-line note on Contacts access, and the one action
    /// that note calls for: asking for access (only from this click, never
    /// on its own), or opening System Settings after a denial.
    private func updateMeCardRow() {
        meCardCheckbox.state = EmailAutofillPreferences.fillFromMeCard ? .on : .off
        switch ContactsAutofillSource.authorizationStatus {
        case .authorized:
            meCardStatusLabel.stringValue = "Your Me card in Contacts is offered first."
            meCardActionButton.isHidden = true
        case .notDetermined:
            meCardStatusLabel.stringValue = "Needs access to Contacts."
            meCardActionButton.title = "Allow Access…"
            meCardActionButton.isHidden = false
        default:
            meCardStatusLabel.stringValue = "Contacts access is off."
            meCardActionButton.title = "Open System Settings…"
            meCardActionButton.isHidden = false
        }
    }

    @objc private func meCardPreferenceChanged() {
        EmailAutofillPreferences.fillFromMeCard = meCardCheckbox.state == .on
    }

    @objc private func meCardActionTapped() {
        switch ContactsAutofillSource.authorizationStatus {
        case .notDetermined:
            ContactsAutofillSource.requestAccessIfNeeded { [weak self] _ in self?.updateMeCardRow() }
        case .authorized:
            break
        default:
            MeCardAutofill.openContactsPrivacySettings()
        }
    }

    // MARK: - Actions

    @objc private func listButtonClicked() {
        switch listButtons.selectedSegment {
        case SettingsListButtons.addSegment: addAddress()
        case SettingsListButtons.removeSegment: deleteSelectedAddress()
        default: break
        }
    }

    @objc private func profileSelectionChanged() {
        selectedProfile = profilePopup.selectedItem?.representedObject as? Profile
        loadAddressesForSelectedProfile()
    }

    @objc private func addAddress() {
        guard let profile = selectedProfile, let window = view.window else { return }
        let sheet = AddressFormSheetController(existing: nil)
        sheet.show(in: window) { [weak self] address in
            guard let self, let address else { return }
            AddressStoreManager.shared.store(forProfileId: profile.id).save(address)
            self.loadAddressesForSelectedProfile()
        }
    }

    @objc private func editSelectedAddress() {
        let row = addressesTableView.selectedRow
        guard let profile = selectedProfile, addresses.indices.contains(row), let window = view.window else { return }
        let existing = addresses[row]
        let sheet = AddressFormSheetController(existing: existing)
        sheet.show(in: window) { [weak self] address in
            guard let self, let address else { return }
            AddressStoreManager.shared.store(forProfileId: profile.id).save(address)
            self.loadAddressesForSelectedProfile()
        }
    }

    @objc private func deleteSelectedAddress() {
        let row = addressesTableView.selectedRow
        guard let profile = selectedProfile, addresses.indices.contains(row) else { return }
        let address = addresses[row]

        guard NSAlert.confirmDestructive(
            message: "Delete Saved Address?",
            informativeText: "The saved address for \(address.fullName.isEmpty ? "this entry" : address.fullName) will be removed.",
            confirmTitle: "Delete"
        ) else { return }

        AddressStoreManager.shared.store(forProfileId: profile.id).delete(id: address.id)
        loadAddressesForSelectedProfile()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        addresses.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionDependentControls()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard addresses.indices.contains(row), let columnIdentifier = tableColumn?.identifier else { return nil }
        let address = addresses[row]
        let text: String
        switch columnIdentifier.rawValue {
        case "fullName":
            text = address.fullName
        case "address":
            text = [address.streetAddress, address.city, address.postalCode].filter { !$0.isEmpty }.joined(separator: ", ")
        default:
            text = ""
        }
        return ListAppearance.textCell(in: tableView, identifier: "addressCell.\(columnIdentifier.rawValue)", text: text)
    }
}
