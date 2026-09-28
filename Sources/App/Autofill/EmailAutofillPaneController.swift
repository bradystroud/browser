import AppKit

/// The "Emails" section of the Autofill Settings pane: the "Suggest email
/// addresses" switch, then per profile the user's own addresses, the
/// site/tenant associations learned from sign-ins, and rules. Same
/// header / table / profile picker / button row layout as the Passwords and
/// Addresses sections, with a segmented control choosing which list the
/// table shows.
final class EmailAutofillPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    private enum Section: Int {
        case addresses, learned, rules
    }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let suggestCheckbox = NSButton(checkboxWithTitle: "Suggest email addresses", target: nil, action: nil)
    private let sectionControl = NSSegmentedControl(
        labels: ["Your Addresses", "Learned Sites", "Rules"], trackingMode: .selectOne, target: nil, action: nil
    )
    private let profilePopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton(title: "Add…", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear All", target: nil, action: nil)

    private var section: Section = .addresses
    private var selectedProfile: Profile?
    private var data = EmailAutofillData()
    private var observers: [NSObjectProtocol] = []

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    override init() {
        super.init()
        setUpViews()
        reload()
        observers.append(NotificationCenter.default.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() })
        observers.append(NotificationCenter.default.addObserver(
            forName: EmailAutofillStoreManager.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.loadData() })
    }

    func reload() {
        selectedProfile = profilePopup.reloadProfiles(keeping: selectedProfile)
        suggestCheckbox.state = EmailAutofillPreferences.suggestEmailAddresses ? .on : .off
        loadData()
    }

    // MARK: - View setup

    private func setUpViews() {
        let margin: CGFloat = 12
        let rowGap: CGFloat = 10
        let headerHeight: CGFloat = 22
        let rowHeight: CGFloat = 28

        let headerLabel = NSTextField(labelWithString: "Email Addresses")
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.frame = NSRect(x: margin, y: view.bounds.height - margin - headerHeight, width: 200, height: headerHeight)
        headerLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(headerLabel)

        suggestCheckbox.frame = NSRect(x: view.bounds.width - margin - 220, y: view.bounds.height - margin - headerHeight, width: 220, height: headerHeight)
        suggestCheckbox.autoresizingMask = [.minXMargin, .minYMargin]
        suggestCheckbox.target = self
        suggestCheckbox.action = #selector(suggestPreferenceChanged)
        view.addSubview(suggestCheckbox)

        let sectionY = view.bounds.height - margin - headerHeight - rowGap - rowHeight
        sectionControl.frame = NSRect(x: margin, y: sectionY, width: view.bounds.width - margin * 2, height: rowHeight)
        sectionControl.autoresizingMask = [.width, .minYMargin]
        sectionControl.selectedSegment = 0
        sectionControl.target = self
        sectionControl.action = #selector(sectionChanged)
        view.addSubview(sectionControl)

        // Bottom-up, as in the other sections.
        var x = margin
        for (button, width, action) in [
            (addButton, 70.0, #selector(addTapped)),
            (editButton, 70.0, #selector(editTapped)),
            (removeButton, 80.0, #selector(removeTapped)),
            (clearButton, 90.0, #selector(clearTapped)),
        ] as [(NSButton, CGFloat, Selector)] {
            button.frame = NSRect(x: x, y: margin, width: width, height: rowHeight)
            button.autoresizingMask = [.maxXMargin, .maxYMargin]
            button.target = self
            button.action = action
            view.addSubview(button)
            x += width + 4
        }

        let profileRowY = margin + rowHeight + rowGap
        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.frame = NSRect(x: margin, y: profileRowY + 6, width: 60, height: 20)
        profileLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(profileLabel)

        profilePopup.frame = NSRect(x: margin + 64, y: profileRowY, width: 200, height: rowHeight)
        profilePopup.autoresizingMask = [.maxXMargin, .maxYMargin]
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        view.addSubview(profilePopup)

        let scrollTop = sectionY - rowGap
        let scrollBottom = profileRowY + rowHeight + rowGap
        scrollView.frame = NSRect(x: margin, y: scrollBottom, width: view.bounds.width - margin * 2, height: max(0, scrollTop - scrollBottom))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(editTapped)
        tableView.target = self
        ListAppearance.apply(to: tableView, in: scrollView)
        scrollView.documentView = tableView
        view.addSubview(scrollView)
        configureColumns()
    }

    private func configureColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        let columns: [(String, String, CGFloat)]
        switch section {
        case .addresses:
            columns = [("email", "Email", 480)]
        case .learned:
            columns = [("email", "Email", 170), ("site", "Site", 140), ("tenant", "Tenant", 90), ("lastUsed", "Last Used", 90)]
        case .rules:
            columns = [("pattern", "Host Pattern", 180), ("tenant", "Tenant", 120), ("email", "Email", 190)]
        }
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        addButton.isHidden = section == .learned
        editButton.isHidden = section != .rules
        clearButton.isHidden = section != .learned
        // Remove sits where Add is when Add is hidden.
        removeButton.frame.origin.x = section == .learned ? 12 : (section == .rules ? 12 + 148 : 12 + 74)
        clearButton.frame.origin.x = 12 + 84
    }

    // MARK: - Data

    private var store: EmailAutofillStore? {
        selectedProfile.map { EmailAutofillStoreManager.store(forProfileId: $0.id) }
    }

    private var learnedRows: [EmailUsageRecord] {
        data.usage.sorted { $0.lastUsed > $1.lastUsed }
    }

    private func loadData() {
        data = store?.data ?? EmailAutofillData()
        tableView.reloadData()
    }

    private func changed() {
        loadData()
        NotificationCenter.default.post(name: EmailAutofillStoreManager.didChangeNotification, object: nil)
    }

    // MARK: - Actions

    @objc private func suggestPreferenceChanged() {
        EmailAutofillPreferences.suggestEmailAddresses = suggestCheckbox.state == .on
    }

    @objc private func sectionChanged() {
        section = Section(rawValue: sectionControl.selectedSegment) ?? .addresses
        configureColumns()
        tableView.reloadData()
    }

    @objc private func profileSelectionChanged() {
        selectedProfile = profilePopup.selectedItem?.representedObject as? Profile
        loadData()
    }

    @objc private func addTapped() {
        guard let store else { return }
        switch section {
        case .addresses:
            guard let text = Self.prompt(title: "Add Email Address", fields: [("Email", "")])?.first else { return }
            if !store.addAddress(text) { NSSound.beep() }
            changed()
        case .rules:
            editRule(nil)
        case .learned:
            break
        }
    }

    @objc private func editTapped() {
        guard section == .rules else { return }
        let row = tableView.selectedRow
        guard data.rules.indices.contains(row) else { return }
        editRule(data.rules[row])
    }

    private func editRule(_ existing: EmailRule?) {
        guard let store else { return }
        guard let values = Self.prompt(
            title: existing == nil ? "Add Email Rule" : "Edit Email Rule",
            message: "On pages whose host matches the pattern (use * as a wildcard, e.g. *.example.com or login.microsoftonline.com), suggest this email first. Tenant is optional: a Microsoft tenant ID or domain, or an Okta/Auth0 subdomain.",
            fields: [("Host pattern", existing?.hostPattern ?? ""), ("Tenant (optional)", existing?.tenant ?? ""), ("Email", existing?.email ?? "")]
        ), values.count == 3 else { return }
        let pattern = values[0].trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty, let email = EmailAddress.normalized(values[2]) else {
            NSSound.beep()
            return
        }
        let tenant = values[1].trimmingCharacters(in: .whitespaces)
        store.saveRule(EmailRule(id: existing?.id ?? UUID().uuidString, hostPattern: pattern,
                                 tenant: tenant.isEmpty ? nil : tenant.lowercased(), email: email))
        changed()
    }

    @objc private func removeTapped() {
        guard let store else { return }
        let row = tableView.selectedRow
        switch section {
        case .addresses:
            guard data.addresses.indices.contains(row) else { return }
            store.removeAddress(data.addresses[row])
        case .learned:
            let rows = learnedRows
            guard rows.indices.contains(row) else { return }
            store.removeUsage(id: rows[row].id)
        case .rules:
            guard data.rules.indices.contains(row) else { return }
            store.removeRule(id: data.rules[row].id)
        }
        changed()
    }

    @objc private func clearTapped() {
        guard let store, section == .learned, !data.usage.isEmpty else { return }
        guard NSAlert.confirmDestructive(
            message: "Clear Learned Sites?",
            informativeText: "Every site and sign-in tenant this profile has learned an email address for will be forgotten. Your addresses and rules are kept.",
            confirmTitle: "Clear All"
        ) else { return }
        store.clearUsage()
        changed()
    }

    /// A small modal form: one text field per entry in `fields`. Returns
    /// the values in the same order, or nil when cancelled.
    private static func prompt(title: String, message: String = "", fields: [(String, String)]) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let rowHeight: CGFloat = 28
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: CGFloat(fields.count) * rowHeight))
        var textFields: [NSTextField] = []
        for (index, field) in fields.enumerated() {
            let y = container.bounds.height - CGFloat(index + 1) * rowHeight + 3
            let label = NSTextField(labelWithString: field.0 + ":")
            label.frame = NSRect(x: 0, y: y + 2, width: 110, height: 20)
            label.alignment = .right
            let textField = NSTextField(string: field.1)
            textField.frame = NSRect(x: 116, y: y, width: 204, height: 22)
            textField.placeholderString = field.0
            container.addSubview(label)
            container.addSubview(textField)
            textFields.append(textField)
        }
        alert.accessoryView = container
        alert.window.initialFirstResponder = textFields.first
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textFields.map(\.stringValue)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch section {
        case .addresses: return data.addresses.count
        case .learned: return data.usage.count
        case .rules: return data.rules.count
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        switch section {
        case .addresses:
            guard data.addresses.indices.contains(row) else { return nil }
            text = data.addresses[row]
        case .learned:
            let rows = learnedRows
            guard rows.indices.contains(row) else { return nil }
            let record = rows[row]
            switch column {
            case "email": text = record.email
            case "site": text = record.host
            case "tenant": text = record.tenantKey.map(Self.tenantDisplay) ?? ""
            default: text = Self.dateFormatter.string(from: record.lastUsed) + (record.count > 1 ? " (\(record.count)×)" : "")
            }
        case .rules:
            guard data.rules.indices.contains(row) else { return nil }
            let rule = data.rules[row]
            switch column {
            case "pattern": text = rule.hostPattern
            case "tenant": text = rule.tenant ?? "Any"
            default: text = rule.email
            }
        }
        return ListAppearance.textCell(in: tableView, identifier: "emailCell.\(column)", text: text)
    }

    /// `microsoft:contoso.com.au` -> `Microsoft: contoso.com.au`.
    private static func tenantDisplay(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = IdentityProviderHints.Provider(rawValue: parts[0]) else { return key }
        return "\(provider.displayName): \(parts[1])"
    }
}
