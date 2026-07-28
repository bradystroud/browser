import AppKit

/// The "Privacy" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside RoutingRulesPaneController and
/// ProfilesPaneController in an NSTabView). Content blocking is per-profile
/// (BlockingSettings, BlockListCore), so this pane starts with a profile
/// picker, then shows that profile's master on/off toggle and per-site
/// allowlist ("turn off blocking on this site") below it. Every change
/// saves immediately via ContentBlockerCoordinator -- there is no separate
/// "Apply" step.
final class PrivacyPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let profilePopup = NSPopUpButton()
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Block ads & trackers in this profile", target: nil, action: nil)
    private let allowlistTableView = NSTableView()

    private var selectedProfile: Profile?
    private var allowlistedHosts: [String] = []
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

    /// Repopulates the profile picker from ProfileManager (a profile may
    /// have been added/renamed/removed elsewhere in Settings), preserving
    /// the current selection if it still exists, then reloads that
    /// profile's settings into the checkbox and allowlist table.
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
        loadSettingsForSelectedProfile()
    }

    // MARK: - View setup

    private func setUpViews() {
        let margin: CGFloat = 12
        let rowGap: CGFloat = 10
        let headerHeight: CGFloat = 22
        let profileRowHeight: CGFloat = 28
        let checkboxRowHeight: CGFloat = 20
        let buttonRowHeight: CGFloat = 28

        let headerLabel = NSTextField(labelWithString: "Privacy")
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
        let addHostButton = NSButton(title: "Add Allowed Site…", target: self, action: #selector(addAllowlistHost))
        addHostButton.frame = NSRect(x: margin, y: margin, width: 150, height: buttonRowHeight)
        addHostButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(addHostButton)

        let removeHostButton = NSButton(title: "Remove", target: self, action: #selector(removeSelectedAllowlistHost))
        removeHostButton.frame = NSRect(x: margin + 154, y: margin, width: 70, height: buttonRowHeight)
        removeHostButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(removeHostButton)

        let allowlistLabelY = margin + buttonRowHeight + rowGap
        let allowlistHeaderLabel = NSTextField(labelWithString: "Allowed sites (blocking is always off here):")
        allowlistHeaderLabel.font = .systemFont(ofSize: 11)
        allowlistHeaderLabel.textColor = .secondaryLabelColor
        allowlistHeaderLabel.frame = NSRect(x: margin, y: allowlistLabelY, width: view.bounds.width - margin * 2, height: 16)
        allowlistHeaderLabel.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(allowlistHeaderLabel)

        let enabledCheckboxY = allowlistLabelY + 16 + rowGap
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledToggled)
        enabledCheckbox.frame = NSRect(x: margin, y: enabledCheckboxY, width: 280, height: checkboxRowHeight)
        enabledCheckbox.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(enabledCheckbox)

        let profileRowY = enabledCheckboxY + checkboxRowHeight + rowGap
        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.frame = NSRect(x: margin, y: profileRowY + 6, width: 60, height: 20)
        profileLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(profileLabel)

        profilePopup.frame = NSRect(x: margin + 64, y: profileRowY, width: 200, height: profileRowHeight)
        profilePopup.autoresizingMask = [.maxXMargin, .maxYMargin]
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        view.addSubview(profilePopup)

        // The allowlist table fills the remaining space between the header
        // and the profile row.
        let scrollView = NSScrollView(frame: NSRect(
            x: margin,
            y: allowlistLabelY + 16 + rowGap * 2 + checkboxRowHeight,
            width: view.bounds.width - margin * 2,
            height: 0  // computed below once we know the header's bottom edge.
        ))
        let scrollTop = view.bounds.height - margin - headerHeight - rowGap
        let scrollBottom = allowlistLabelY + 16 + rowGap
        scrollView.frame = NSRect(x: margin, y: scrollBottom, width: view.bounds.width - margin * 2, height: max(0, scrollTop - scrollBottom))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let hostColumn = NSTableColumn(identifier: .init("host"))
        hostColumn.title = "Host"
        hostColumn.width = 460

        allowlistTableView.addTableColumn(hostColumn)
        allowlistTableView.dataSource = self
        allowlistTableView.delegate = self
        allowlistTableView.usesAlternatingRowBackgroundColors = true
        scrollView.documentView = allowlistTableView
        view.addSubview(scrollView)
    }

    // MARK: - Data

    private func loadSettingsForSelectedProfile() {
        guard let profile = selectedProfile else {
            enabledCheckbox.isEnabled = false
            allowlistedHosts = []
            allowlistTableView.reloadData()
            return
        }
        enabledCheckbox.isEnabled = true
        let settings = ContentBlockerCoordinator.shared.settings(forProfileName: profile.name)
        enabledCheckbox.state = settings.isEnabled ? .on : .off
        allowlistedHosts = settings.allowlistedHosts
        allowlistTableView.reloadData()
    }

    private func saveCurrentSettings() {
        guard let profile = selectedProfile else { return }
        let settings = BlockingSettings(isEnabled: enabledCheckbox.state == .on, allowlistedHosts: allowlistedHosts)
        ContentBlockerCoordinator.shared.updateSettings(settings, forProfileName: profile.name)
    }

    // MARK: - Actions

    @objc private func profileSelectionChanged() {
        selectedProfile = profilePopup.selectedItem?.representedObject as? Profile
        loadSettingsForSelectedProfile()
    }

    @objc private func enabledToggled() {
        saveCurrentSettings()
    }

    @objc private func addAllowlistHost() {
        guard selectedProfile != nil else { return }

        let alert = NSAlert()
        alert.messageText = "Add Allowed Site"
        alert.informativeText = "Content blocking will be turned off for this domain and its subdomains in this profile."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "example.com"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let host = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, !allowlistedHosts.contains(host) else { return }

        allowlistedHosts.append(host)
        allowlistTableView.reloadData()
        saveCurrentSettings()
    }

    @objc private func removeSelectedAllowlistHost() {
        let index = allowlistTableView.selectedRow
        guard allowlistedHosts.indices.contains(index) else { return }
        allowlistedHosts.remove(at: index)
        allowlistTableView.reloadData()
        saveCurrentSettings()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        allowlistedHosts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard allowlistedHosts.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("hostCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = allowlistedHosts[row]
        return cell
    }
}
