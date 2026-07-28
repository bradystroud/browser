import AppKit

/// The "Addresses" section of the Autofill Settings pane (browser-ojh.2) --
/// same profile-picker-then-table layout as PasswordsPaneController/
/// CardsPaneController. Not secret data, so unlike those two, this pane
/// shows the address directly in the table -- no Touch-ID-gated reveal --
/// and additionally supports adding/editing (AddressFormSheetController),
/// since there's no page-submit flow guaranteed to ever populate this list
/// otherwise (a user might want to add their own address without first
/// filling out some site's checkout form).
final class AddressesPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let profilePopup = NSPopUpButton()
    private let addressesTableView = NSTableView()

    private var selectedProfile: Profile?
    private var addresses: [StoredAddress] = []
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

    func reload() {
        let profiles = ProfileManager.shared.profiles
        profilePopup.removeAllItems()
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.representedObject = profile
            profilePopup.menu?.addItem(item)
        }

        let stillExists = selectedProfile.flatMap { current in profiles.first { $0.id == current.id } }
        let toSelect = stillExists ?? profiles.first
        if let toSelect, let index = profiles.firstIndex(where: { $0.id == toSelect.id }) {
            profilePopup.selectItem(at: index)
        }
        selectedProfile = toSelect
        loadAddressesForSelectedProfile()
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

        let profileRowY = margin + buttonRowHeight + rowGap
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
        scrollView.borderType = .bezelBorder

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
        addressesTableView.usesAlternatingRowBackgroundColors = true
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
        addresses = AddressStoreManager.shared.store(forProfileName: profile.name).all()
            .sorted { $0.fullName == $1.fullName ? $0.streetAddress < $1.streetAddress : $0.fullName < $1.fullName }
        addressesTableView.reloadData()
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
            AddressStoreManager.shared.store(forProfileName: profile.name).save(address)
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
            AddressStoreManager.shared.store(forProfileName: profile.name).save(address)
            self.loadAddressesForSelectedProfile()
        }
    }

    @objc private func deleteSelectedAddress() {
        let row = addressesTableView.selectedRow
        guard let profile = selectedProfile, addresses.indices.contains(row) else { return }
        let address = addresses[row]

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Saved Address?"
        alert.informativeText = "The saved address for \(address.fullName.isEmpty ? "this entry" : address.fullName) will be removed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        AddressStoreManager.shared.store(forProfileName: profile.name).delete(id: address.id)
        loadAddressesForSelectedProfile()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        addresses.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard addresses.indices.contains(row), let columnIdentifier = tableColumn?.identifier else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("addressCell.\(columnIdentifier.rawValue)")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        let address = addresses[row]
        switch columnIdentifier.rawValue {
        case "fullName":
            cell.stringValue = address.fullName
        case "address":
            cell.stringValue = [address.streetAddress, address.city, address.postalCode].filter { !$0.isEmpty }.joined(separator: ", ")
        default:
            cell.stringValue = ""
        }
        return cell
    }
}
