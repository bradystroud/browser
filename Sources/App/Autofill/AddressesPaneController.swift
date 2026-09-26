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
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let profilePopup = NSPopUpButton()
    private let addressesTableView = NSTableView()

    private var selectedProfile: Profile?
    private var addresses: [StoredAddress] = []
    private var profileChangeObserver: NSObjectProtocol?
    private var appActiveObserver: NSObjectProtocol?

    private let meCardCheckbox = NSButton(checkboxWithTitle: "Fill from my contact card", target: nil, action: nil)
    private let meCardStatusLabel = NSTextField(labelWithString: "")
    private let meCardActionButton = NSButton(title: "", target: nil, action: nil)

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
        let margin: CGFloat = 12
        let rowGap: CGFloat = 10
        let headerHeight: CGFloat = 22
        let profileRowHeight: CGFloat = 28
        let buttonRowHeight: CGFloat = 28

        let headerLabel = NSTextField(labelWithString: "Addresses")
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.frame = NSRect(x: margin, y: view.bounds.height - margin - headerHeight, width: view.bounds.width - margin * 2, height: headerHeight)
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        let addButton = NSButton(title: "Add…", target: self, action: #selector(addAddress))
        addButton.frame = NSRect(x: margin, y: margin, width: 70, height: buttonRowHeight)
        addButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(addButton)

        let editButton = NSButton(title: "Edit…", target: self, action: #selector(editSelectedAddress))
        editButton.frame = NSRect(x: margin + 74, y: margin, width: 70, height: buttonRowHeight)
        editButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(editButton)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelectedAddress))
        deleteButton.frame = NSRect(x: margin + 148, y: margin, width: 70, height: buttonRowHeight)
        deleteButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(deleteButton)

        let meCardRowY = margin + buttonRowHeight + rowGap
        meCardCheckbox.frame = NSRect(x: margin, y: meCardRowY + 4, width: 190, height: 20)
        meCardCheckbox.autoresizingMask = [.maxXMargin, .maxYMargin]
        meCardCheckbox.target = self
        meCardCheckbox.action = #selector(meCardPreferenceChanged)
        view.addSubview(meCardCheckbox)

        meCardStatusLabel.font = .systemFont(ofSize: 11)
        meCardStatusLabel.textColor = .secondaryLabelColor
        meCardStatusLabel.lineBreakMode = .byTruncatingTail
        meCardStatusLabel.frame = NSRect(x: margin + 194, y: meCardRowY + 6, width: view.bounds.width - margin * 2 - 194 - 170, height: 16)
        meCardStatusLabel.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(meCardStatusLabel)

        meCardActionButton.frame = NSRect(x: view.bounds.width - margin - 166, y: meCardRowY, width: 166, height: buttonRowHeight)
        meCardActionButton.autoresizingMask = [.minXMargin, .maxYMargin]
        meCardActionButton.target = self
        meCardActionButton.action = #selector(meCardActionTapped)
        view.addSubview(meCardActionButton)

        let profileRowY = meCardRowY + buttonRowHeight + rowGap
        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.frame = NSRect(x: margin, y: profileRowY + 6, width: 60, height: 20)
        profileLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(profileLabel)

        profilePopup.frame = NSRect(x: margin + 64, y: profileRowY, width: 200, height: profileRowHeight)
        profilePopup.autoresizingMask = [.maxXMargin, .maxYMargin]
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        view.addSubview(profilePopup)

        let scrollTop = view.bounds.height - margin - headerHeight - rowGap
        let scrollBottom = profileRowY + profileRowHeight + rowGap
        let scrollView = NSScrollView(frame: NSRect(x: margin, y: scrollBottom, width: view.bounds.width - margin * 2, height: max(0, scrollTop - scrollBottom)))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let nameColumn = NSTableColumn(identifier: .init("fullName"))
        nameColumn.title = "Name"
        nameColumn.width = 160

        let addressColumn = NSTableColumn(identifier: .init("address"))
        addressColumn.title = "Address"
        addressColumn.width = 280

        addressesTableView.addTableColumn(nameColumn)
        addressesTableView.addTableColumn(addressColumn)
        addressesTableView.dataSource = self
        addressesTableView.delegate = self
        ListAppearance.apply(to: addressesTableView, in: scrollView)
        scrollView.documentView = addressesTableView
        view.addSubview(scrollView)
    }

    // MARK: - Data

    private func loadAddressesForSelectedProfile() {
        guard let profile = selectedProfile else {
            addresses = []
            addressesTableView.reloadData()
            return
        }
        addresses = AddressStoreManager.shared.store(forProfileId: profile.id).all()
            .sorted { $0.fullName == $1.fullName ? $0.streetAddress < $1.streetAddress : $0.fullName < $1.fullName }
        addressesTableView.reloadData()
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
