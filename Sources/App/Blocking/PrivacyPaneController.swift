import AppKit

/// The "Privacy" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside RoutingRulesPaneController and
/// ProfilesPaneController in an NSTabView). Content blocking is per-profile
/// (BlockingSettings, BlockListCore), so this pane starts with a profile
/// picker, then shows that profile's master on/off toggle, remembered
/// per-site permission decisions (camera/microphone/geolocation/
/// notifications -- browser-12m.2.1, PermissionStore), and per-site
/// content-blocking allowlist ("turn off blocking on this site") below it.
/// Every change saves immediately via ContentBlockerCoordinator/
/// PermissionStore -- there is no separate "Apply" step.
final class PrivacyPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    private static let margin: CGFloat = 12
    private static let rowGap: CGFloat = 10
    private static let headerHeight: CGFloat = 22
    private static let profileRowHeight: CGFloat = 28
    private static let checkboxRowHeight: CGFloat = 20
    private static let buttonRowHeight: CGFloat = 28
    private static let sectionLabelHeight: CGFloat = 16
    private static let permissionsTableHeight: CGFloat = 110
    private static let allowlistTableHeight: CGFloat = 100

    /// This pane's natural content height -- SettingsWindowController
    /// resizes the Settings window to this whenever Privacy becomes the
    /// selected tab (see GeneralPaneController.preferredContentHeight's
    /// doc comment for why panes with more content than
    /// SettingsPaneController's generic 400pt default need their own exact
    /// value). Computed bottom-up from the same constants setUpViews lays
    /// out with top-down, so the two can't drift apart: margin, header,
    /// Link Handling section, profile row, ad-block + threat-warning
    /// checkboxes, the Site Permissions section (label + table + button
    /// row), the Allowed Sites section (label + table + button row), and
    /// the final bottom margin.
    static let preferredContentHeight: CGFloat =
        margin + headerHeight + rowGap + sectionLabelHeight + 4 + checkboxRowHeight + 2 + checkboxRowHeight
            + rowGap + profileRowHeight + rowGap + checkboxRowHeight + 4 + checkboxRowHeight
            + rowGap + sectionLabelHeight + 4 + permissionsTableHeight + rowGap + buttonRowHeight
            + rowGap + sectionLabelHeight + 4 + allowlistTableHeight + rowGap + buttonRowHeight + margin
    var preferredContentHeight: CGFloat { Self.preferredContentHeight }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: PrivacyPaneController.preferredContentHeight))

    private let profilePopup = NSPopUpButton()
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Block ads & trackers in this profile", target: nil, action: nil)
    /// browser-12m.6: independent of `enabledCheckbox` above -- a separate
    /// list category with separate treatment (a warning interstitial the
    /// user can click through, vs. ads' silent cancel), so it gets its own
    /// toggle and its own persisted ThreatWarningSettings rather than
    /// piggybacking on BlockingSettings.
    private let threatWarningCheckbox = NSButton(checkboxWithTitle: "Warn about dangerous sites (phishing/malware)", target: nil, action: nil)
    private let allowlistTableView = NSTableView()

    /// browser-12m.2.1: remembered per-origin camera/microphone/
    /// geolocation/notifications decisions for the selected profile (see
    /// PermissionStore) -- a site/permission/allowed-or-denied list, with
    /// per-row removal and a "Reset All" for the whole profile.
    private let permissionsTableView = NSTableView()
    private var permissionEntries: [PermissionDecisionEntry] = []

    /// Global (not per-profile) settings, per browser-ymx -- see
    /// LinkHandlingPreferences' own doc comment for why these live outside
    /// the profile-scoped content below.
    private let stripTrackingParamsCheckbox = NSButton(checkboxWithTitle: "Strip tracking parameters from links (utm_*, fbclid, gclid, …)", target: nil, action: nil)
    private let unshortenLinksCheckbox = NSButton(checkboxWithTitle: "Follow shortened links (t.co, bit.ly, …) before opening", target: nil, action: nil)

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
    /// profile's settings into the checkboxes and both tables.
    func reload() {
        stripTrackingParamsCheckbox.state = LinkHandlingPreferences.stripTrackingParams ? .on : .off
        unshortenLinksCheckbox.state = LinkHandlingPreferences.unshortenLinks ? .on : .off

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

    /// Top-down: header, then the global Link Handling section, then the
    /// profile picker and everything scoped to it (ad-block/threat-warning
    /// toggles, the Site Permissions table, the Allowed Sites table), each
    /// pinned to the top (.minYMargin) so extra height the window picks up
    /// collects below the last section instead of pushing content toward
    /// the bottom -- except the very last row (Allowed Sites' Add/Remove
    /// buttons), which stays bottom-pinned like every other pane's
    /// trailing action row.
    private func setUpViews() {
        let margin = Self.margin
        let rowGap = Self.rowGap
        let headerHeight = Self.headerHeight
        let profileRowHeight = Self.profileRowHeight
        let checkboxRowHeight = Self.checkboxRowHeight
        let buttonRowHeight = Self.buttonRowHeight
        let sectionLabelHeight = Self.sectionLabelHeight

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

        // Link Handling -- global, not per-profile (browser-ymx), so it
        // sits above the profile-scoped content below rather than inside
        // it.
        let linkHandlingHeaderY = headerLabel.frame.minY - rowGap - sectionLabelHeight
        let linkHandlingHeaderLabel = NSTextField(labelWithString: "Link Handling")
        linkHandlingHeaderLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        linkHandlingHeaderLabel.textColor = .secondaryLabelColor
        linkHandlingHeaderLabel.frame = NSRect(x: margin, y: linkHandlingHeaderY, width: view.bounds.width - margin * 2, height: sectionLabelHeight)
        linkHandlingHeaderLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(linkHandlingHeaderLabel)

        let stripCheckboxY = linkHandlingHeaderY - 4 - checkboxRowHeight
        stripTrackingParamsCheckbox.target = self
        stripTrackingParamsCheckbox.action = #selector(stripTrackingParamsToggled)
        stripTrackingParamsCheckbox.frame = NSRect(x: margin, y: stripCheckboxY, width: view.bounds.width - margin * 2, height: checkboxRowHeight)
        stripTrackingParamsCheckbox.autoresizingMask = [.width, .minYMargin]
        view.addSubview(stripTrackingParamsCheckbox)

        let unshortenCheckboxY = stripCheckboxY - 2 - checkboxRowHeight
        unshortenLinksCheckbox.target = self
        unshortenLinksCheckbox.action = #selector(unshortenLinksToggled)
        unshortenLinksCheckbox.frame = NSRect(x: margin, y: unshortenCheckboxY, width: view.bounds.width - margin * 2, height: checkboxRowHeight)
        unshortenLinksCheckbox.autoresizingMask = [.width, .minYMargin]
        view.addSubview(unshortenLinksCheckbox)

        // Profile picker -- same "right after the global section" position
        // every other per-profile pane uses (Start Page, Passwords, Cards,
        // Addresses), rather than buried near the bottom as it used to be.
        let profileRowY = unshortenCheckboxY - rowGap - profileRowHeight
        let profileLabel = NSTextField(labelWithString: "Profile:")
        profileLabel.frame = NSRect(x: margin, y: profileRowY + 6, width: 60, height: 20)
        profileLabel.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(profileLabel)

        profilePopup.frame = NSRect(x: margin + 64, y: profileRowY, width: 200, height: profileRowHeight)
        profilePopup.autoresizingMask = [.maxXMargin, .minYMargin]
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        view.addSubview(profilePopup)

        let enabledCheckboxY = profileRowY - rowGap - checkboxRowHeight
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledToggled)
        enabledCheckbox.frame = NSRect(x: margin, y: enabledCheckboxY, width: 280, height: checkboxRowHeight)
        enabledCheckbox.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(enabledCheckbox)

        let threatWarningCheckboxY = enabledCheckboxY - 4 - checkboxRowHeight
        threatWarningCheckbox.target = self
        threatWarningCheckbox.action = #selector(threatWarningToggled)
        threatWarningCheckbox.frame = NSRect(x: margin, y: threatWarningCheckboxY, width: 280, height: checkboxRowHeight)
        threatWarningCheckbox.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(threatWarningCheckbox)

        // Site Permissions -- header, table, then Remove/Reset All below
        // the table (same order Profiles/Passwords/Cards/Addresses use).
        let permissionsHeaderY = threatWarningCheckboxY - rowGap - sectionLabelHeight
        let permissionsHeaderLabel = NSTextField(labelWithString: "Site Permissions")
        permissionsHeaderLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        permissionsHeaderLabel.textColor = .secondaryLabelColor
        permissionsHeaderLabel.frame = NSRect(x: margin, y: permissionsHeaderY, width: view.bounds.width - margin * 2, height: sectionLabelHeight)
        permissionsHeaderLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(permissionsHeaderLabel)

        let permissionsTableY = permissionsHeaderY - 4 - Self.permissionsTableHeight
        let permissionsScrollView = NSScrollView(frame: NSRect(
            x: margin, y: permissionsTableY, width: view.bounds.width - margin * 2, height: Self.permissionsTableHeight
        ))
        permissionsScrollView.autoresizingMask = [.width, .minYMargin]
        permissionsScrollView.hasVerticalScroller = true
        permissionsScrollView.borderType = .bezelBorder

        let originColumn = NSTableColumn(identifier: .init("origin"))
        originColumn.title = "Site"
        originColumn.width = 250
        let kindColumn = NSTableColumn(identifier: .init("kind"))
        kindColumn.title = "Permission"
        kindColumn.width = 140
        let decisionColumn = NSTableColumn(identifier: .init("decision"))
        decisionColumn.title = "Decision"
        decisionColumn.width = 90

        permissionsTableView.addTableColumn(originColumn)
        permissionsTableView.addTableColumn(kindColumn)
        permissionsTableView.addTableColumn(decisionColumn)
        permissionsTableView.dataSource = self
        permissionsTableView.delegate = self
        permissionsTableView.usesAlternatingRowBackgroundColors = true
        permissionsScrollView.documentView = permissionsTableView
        view.addSubview(permissionsScrollView)

        let permissionsButtonRowY = permissionsTableY - rowGap - buttonRowHeight
        let removePermissionButton = NSButton(title: "Remove", target: self, action: #selector(removeSelectedPermission))
        removePermissionButton.frame = NSRect(x: margin, y: permissionsButtonRowY, width: 90, height: buttonRowHeight)
        removePermissionButton.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(removePermissionButton)

        let resetAllButton = NSButton(title: "Reset All…", target: self, action: #selector(resetAllPermissions))
        resetAllButton.frame = NSRect(x: margin + 94, y: permissionsButtonRowY, width: 100, height: buttonRowHeight)
        resetAllButton.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(resetAllButton)

        // Allowed Sites (content blocking) -- unchanged section, just
        // repositioned below Site Permissions instead of below the
        // checkboxes directly.
        let allowlistHeaderY = permissionsButtonRowY - rowGap - sectionLabelHeight
        let allowlistHeaderLabel = NSTextField(labelWithString: "Allowed sites (blocking is always off here):")
        allowlistHeaderLabel.font = .systemFont(ofSize: 11)
        allowlistHeaderLabel.textColor = .secondaryLabelColor
        allowlistHeaderLabel.frame = NSRect(x: margin, y: allowlistHeaderY, width: view.bounds.width - margin * 2, height: sectionLabelHeight)
        allowlistHeaderLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(allowlistHeaderLabel)

        // The allowlist table fills the remaining space between its
        // header and the Add/Remove buttons pinned to the very bottom.
        let addHostButton = NSButton(title: "Add Allowed Site…", target: self, action: #selector(addAllowlistHost))
        addHostButton.frame = NSRect(x: margin, y: margin, width: 150, height: buttonRowHeight)
        addHostButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(addHostButton)

        let removeHostButton = NSButton(title: "Remove", target: self, action: #selector(removeSelectedAllowlistHost))
        removeHostButton.frame = NSRect(x: margin + 154, y: margin, width: 70, height: buttonRowHeight)
        removeHostButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(removeHostButton)

        let allowlistScrollTop = allowlistHeaderY - 4
        let allowlistScrollBottom = margin + buttonRowHeight + rowGap
        let allowlistScrollView = NSScrollView(frame: NSRect(
            x: margin, y: allowlistScrollBottom, width: view.bounds.width - margin * 2,
            height: max(0, allowlistScrollTop - allowlistScrollBottom)
        ))
        allowlistScrollView.autoresizingMask = [.width, .height]
        allowlistScrollView.hasVerticalScroller = true
        allowlistScrollView.borderType = .bezelBorder

        let hostColumn = NSTableColumn(identifier: .init("host"))
        hostColumn.title = "Host"
        hostColumn.width = 460

        allowlistTableView.addTableColumn(hostColumn)
        allowlistTableView.dataSource = self
        allowlistTableView.delegate = self
        allowlistTableView.usesAlternatingRowBackgroundColors = true
        allowlistScrollView.documentView = allowlistTableView
        view.addSubview(allowlistScrollView)
    }

    // MARK: - Data

    private func loadSettingsForSelectedProfile() {
        guard let profile = selectedProfile else {
            enabledCheckbox.isEnabled = false
            threatWarningCheckbox.isEnabled = false
            allowlistedHosts = []
            allowlistTableView.reloadData()
            permissionEntries = []
            permissionsTableView.reloadData()
            return
        }
        enabledCheckbox.isEnabled = true
        threatWarningCheckbox.isEnabled = true
        let settings = ContentBlockerCoordinator.shared.settings(forProfileId: profile.id)
        enabledCheckbox.state = settings.isEnabled ? .on : .off
        allowlistedHosts = settings.allowlistedHosts
        allowlistTableView.reloadData()
        let threatSettings = ThreatListCoordinator.shared.settings(forProfileId: profile.id)
        threatWarningCheckbox.state = threatSettings.isEnabled ? .on : .off
        loadPermissionsForSelectedProfile()
    }

    private func loadPermissionsForSelectedProfile() {
        guard let profile = selectedProfile else {
            permissionEntries = []
            permissionsTableView.reloadData()
            return
        }
        permissionEntries = PermissionStoreManager.shared.store(for: profile).allDecisions()
        permissionsTableView.reloadData()
    }

    private func saveCurrentSettings() {
        guard let profile = selectedProfile else { return }
        let settings = BlockingSettings(isEnabled: enabledCheckbox.state == .on, allowlistedHosts: allowlistedHosts)
        ContentBlockerCoordinator.shared.updateSettings(settings, forProfileId: profile.id)
    }

    private func saveThreatWarningSettings() {
        guard let profile = selectedProfile else { return }
        let settings = ThreatWarningSettings(isEnabled: threatWarningCheckbox.state == .on)
        ThreatListCoordinator.shared.updateSettings(settings, forProfileId: profile.id)
    }

    private static func displayName(forKind kind: String) -> String {
        switch kind {
        case "camera": return "Camera"
        case "microphone": return "Microphone"
        case "geolocation": return "Location"
        case "notifications": return "Notifications"
        default: return kind
        }
    }

    // MARK: - Actions

    @objc private func profileSelectionChanged() {
        selectedProfile = profilePopup.selectedItem?.representedObject as? Profile
        loadSettingsForSelectedProfile()
    }

    @objc private func enabledToggled() {
        saveCurrentSettings()
    }

    @objc private func threatWarningToggled() {
        saveThreatWarningSettings()
    }

    @objc private func stripTrackingParamsToggled() {
        LinkHandlingPreferences.stripTrackingParams = stripTrackingParamsCheckbox.state == .on
    }

    @objc private func unshortenLinksToggled() {
        LinkHandlingPreferences.unshortenLinks = unshortenLinksCheckbox.state == .on
    }

    @objc private func removeSelectedPermission() {
        let row = permissionsTableView.selectedRow
        guard let profile = selectedProfile, permissionEntries.indices.contains(row) else { return }
        let entry = permissionEntries[row]
        PermissionStoreManager.shared.store(for: profile).removeDecision(origin: entry.origin, kind: entry.kind)
        loadPermissionsForSelectedProfile()
    }

    @objc private func resetAllPermissions() {
        guard let profile = selectedProfile, !permissionEntries.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset All Site Permissions?"
        alert.informativeText = "Every remembered camera/microphone/location/notification decision for \u{201C}\(profile.name)\u{201D} will be forgotten. Sites will ask again next time."
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        PermissionStoreManager.shared.store(for: profile).resetAll()
        loadPermissionsForSelectedProfile()
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
        if tableView === permissionsTableView { return permissionEntries.count }
        return allowlistedHosts.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === permissionsTableView {
            guard permissionEntries.indices.contains(row), let columnIdentifier = tableColumn?.identifier else { return nil }
            let entry = permissionEntries[row]
            let identifier = NSUserInterfaceItemIdentifier("permissionCell.\(columnIdentifier.rawValue)")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
                ?? NSTextField(labelWithString: "")
            cell.identifier = identifier
            switch columnIdentifier.rawValue {
            case "origin":
                cell.stringValue = entry.origin
            case "kind":
                cell.stringValue = Self.displayName(forKind: entry.kind)
            case "decision":
                cell.stringValue = entry.allowed ? "Allowed" : "Denied"
            default:
                cell.stringValue = ""
            }
            return cell
        }

        guard allowlistedHosts.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("hostCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = allowlistedHosts[row]
        return cell
    }
}
