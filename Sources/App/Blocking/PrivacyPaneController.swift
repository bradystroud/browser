import AppKit

/// The "Privacy" pane of the Settings window (see SettingsWindowController).
/// Two groups: the global link-handling toggles (browser-ymx), then
/// everything scoped to the picked profile -- content blocking
/// (BlockingSettings, BlockListCore) and its allowlist ("turn off blocking
/// on this site"), the dangerous-site warning (browser-12m.6), and the
/// remembered per-site camera/microphone/geolocation/notifications decisions
/// (browser-12m.2.1, PermissionStore). Every change saves immediately via
/// ContentBlockerCoordinator/ThreatListCoordinator/PermissionStore -- there
/// is no separate "Apply" step.
final class PrivacyPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    private static let permissionsTableHeight: CGFloat = 110
    private static let allowlistTableHeight: CGFloat = 100

    private let form = SettingsForm()
    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat { form.fittingHeight }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 560))

    private let profilePopup = NSPopUpButton()
    private let enabledCheckbox = NSButton(checkboxWithTitle: "Block ads & trackers in this profile", target: nil, action: nil)
    /// browser-12m.6: independent of `enabledCheckbox` above -- a separate
    /// list category with separate treatment (a warning interstitial the
    /// user can click through, vs. ads' silent cancel), so it gets its own
    /// toggle and its own persisted ThreatWarningSettings rather than
    /// piggybacking on BlockingSettings.
    private let threatWarningCheckbox = NSButton(checkboxWithTitle: "Warn about dangerous sites (phishing/malware)", target: nil, action: nil)
    private let allowlistTableView = NSTableView()
    private let allowlistButtons = SettingsListButtons(target: nil, action: nil)

    /// browser-12m.2.1: remembered per-origin camera/microphone/
    /// geolocation/notifications decisions for the selected profile (see
    /// PermissionStore) -- a site/permission/allowed-or-denied list, with
    /// per-row removal and a "Reset All" for the whole profile.
    private let permissionsTableView = NSTableView()
    private var permissionEntries: [PermissionDecisionEntry] = []
    /// Remove only: a decision is made by a site asking, never added here.
    private let removePermissionControl: NSSegmentedControl = {
        let control = NSSegmentedControl(
            images: [NSImage(named: NSImage.removeTemplateName)!],
            trackingMode: .momentary, target: nil, action: nil)
        control.segmentStyle = .smallSquare
        control.setWidth(24, forSegment: 0)
        control.setToolTip("Remove", forSegment: 0)
        return control
    }()
    private let resetAllPermissionsButton = NSButton(title: "Reset All…", target: nil, action: nil)

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

        selectedProfile = profilePopup.reloadProfiles(keeping: selectedProfile)
        loadSettingsForSelectedProfile()
    }

    // MARK: - View setup

    /// The global link toggles first, then the profile picker and everything
    /// scoped to it: content blocking and its allowlist, the dangerous-site
    /// warning, and the remembered site permissions.
    private func setUpViews() {
        stripTrackingParamsCheckbox.target = self
        stripTrackingParamsCheckbox.action = #selector(stripTrackingParamsToggled)
        unshortenLinksCheckbox.target = self
        unshortenLinksCheckbox.action = #selector(unshortenLinksToggled)
        form.addRow("Links:", stripTrackingParamsCheckbox)
        form.addRow(nil, unshortenLinksCheckbox)

        form.beginSection()
        profilePopup.target = self
        profilePopup.action = #selector(profileSelectionChanged)
        form.addRow("Profile:", profilePopup)

        // Content blocking.
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledToggled)
        form.addRow("Content blocking:", enabledCheckbox).topPadding = Self.groupGap
        // The report is something you read, not a setting, so it opens its
        // own window (browser-e7r) -- the same one the shield popover opens.
        let privacyReportButton = NSButton(title: "Privacy Report…", target: self, action: #selector(showPrivacyReport))
        form.addRow(nil, privacyReportButton)

        let allowlistScrollView = NSScrollView()
        allowlistScrollView.hasVerticalScroller = true
        let hostColumn = NSTableColumn(identifier: .init("host"))
        hostColumn.title = "Host"
        hostColumn.width = 360
        allowlistTableView.addTableColumn(hostColumn)
        allowlistTableView.dataSource = self
        allowlistTableView.delegate = self
        ListAppearance.apply(to: allowlistTableView, in: allowlistScrollView)
        allowlistScrollView.documentView = allowlistTableView
        allowlistButtons.target = self
        allowlistButtons.action = #selector(allowlistButtonClicked(_:))
        addTableRow("Allowed sites:", tableBlock(allowlistScrollView, height: Self.allowlistTableHeight, controls: [allowlistButtons]))
        form.addFootnote(SettingsForm.footnote("Content blocking is always off on these sites and their subdomains."))

        // Threat protection.
        threatWarningCheckbox.target = self
        threatWarningCheckbox.action = #selector(threatWarningToggled)
        form.addRow("Dangerous sites:", threatWarningCheckbox).topPadding = Self.groupGap

        // Site permissions.
        let permissionsScrollView = NSScrollView()
        permissionsScrollView.hasVerticalScroller = true
        let originColumn = NSTableColumn(identifier: .init("origin"))
        originColumn.title = "Site"
        originColumn.width = 180
        let kindColumn = NSTableColumn(identifier: .init("kind"))
        kindColumn.title = "Permission"
        kindColumn.width = 100
        let decisionColumn = NSTableColumn(identifier: .init("decision"))
        decisionColumn.title = "Decision"
        decisionColumn.width = 70
        permissionsTableView.addTableColumn(originColumn)
        permissionsTableView.addTableColumn(kindColumn)
        permissionsTableView.addTableColumn(decisionColumn)
        permissionsTableView.dataSource = self
        permissionsTableView.delegate = self
        ListAppearance.apply(to: permissionsTableView, in: permissionsScrollView)
        permissionsScrollView.documentView = permissionsTableView
        removePermissionControl.target = self
        removePermissionControl.action = #selector(removeSelectedPermission)
        resetAllPermissionsButton.target = self
        resetAllPermissionsButton.action = #selector(resetAllPermissions)
        resetAllPermissionsButton.controlSize = .small
        addTableRow("Site permissions:", tableBlock(
            permissionsScrollView, height: Self.permissionsTableHeight,
            controls: [removePermissionControl, resetAllPermissionsButton]))
        form.install(in: view)
        updateListButtons()
    }

    /// Extra space above each profile-scoped group, short of a full section
    /// break: a separator there would read as leaving the profile's scope.
    private static let groupGap: CGFloat = SettingsForm.sectionSpacing - SettingsForm.rowSpacing

    /// A row whose control is a table: its label sits level with the
    /// table's top edge rather than on a baseline.
    private func addTableRow(_ label: String, _ block: NSView) {
        let row = form.addRow(SettingsForm.label(label), [block])
        row.rowAlignment = .none
        row.yPlacement = .top
        row.topPadding = SettingsForm.rowSpacing
    }

    private func updateListButtons() {
        allowlistButtons.setEnabled(selectedProfile != nil, forSegment: SettingsListButtons.addSegment)
        allowlistButtons.canRemove = allowlistedHosts.indices.contains(allowlistTableView.selectedRow)
        removePermissionControl.setEnabled(permissionEntries.indices.contains(permissionsTableView.selectedRow), forSegment: 0)
        resetAllPermissionsButton.isEnabled = !permissionEntries.isEmpty
    }

    // MARK: - Data

    private func loadSettingsForSelectedProfile() {
        defer { updateListButtons() }
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
        defer { updateListButtons() }
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

        guard NSAlert.confirmDestructive(
            message: "Reset All Site Permissions?",
            informativeText: "Every remembered camera/microphone/location/notification decision for \u{201C}\(profile.name)\u{201D} will be forgotten. Sites will ask again next time.",
            confirmTitle: "Reset All"
        ) else { return }

        PermissionStoreManager.shared.store(for: profile).resetAll()
        loadPermissionsForSelectedProfile()
    }

    /// Opens the 30-day report for whichever profile this pane is showing --
    /// the same window the shield popover's own link opens, so there is one
    /// report rather than two views that could disagree.
    @objc private func showPrivacyReport() {
        guard let profile = selectedProfile else { return }
        PrivacyReportWindowController.shared.show(for: profile)
    }

    @objc private func allowlistButtonClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case SettingsListButtons.addSegment: addAllowlistHost()
        case SettingsListButtons.removeSegment: removeSelectedAllowlistHost()
        default: break
        }
    }

    private func addAllowlistHost() {
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
        updateListButtons()
        saveCurrentSettings()
    }

    private func removeSelectedAllowlistHost() {
        let index = allowlistTableView.selectedRow
        guard allowlistedHosts.indices.contains(index) else { return }
        allowlistedHosts.remove(at: index)
        allowlistTableView.reloadData()
        updateListButtons()
        saveCurrentSettings()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === permissionsTableView { return permissionEntries.count }
        return allowlistedHosts.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateListButtons()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === permissionsTableView {
            guard permissionEntries.indices.contains(row), let columnIdentifier = tableColumn?.identifier else { return nil }
            let entry = permissionEntries[row]
            let text: String
            switch columnIdentifier.rawValue {
            case "origin":
                text = entry.origin
            case "kind":
                text = Self.displayName(forKind: entry.kind)
            case "decision":
                text = entry.allowed ? "Allowed" : "Denied"
            default:
                text = ""
            }
            return ListAppearance.textCell(in: tableView, identifier: "permissionCell.\(columnIdentifier.rawValue)", text: text)
        }

        guard allowlistedHosts.indices.contains(row) else { return nil }
        return ListAppearance.textCell(in: tableView, identifier: "hostCell", text: allowlistedHosts[row])
    }
}

/// A fixed-height table in the form's control column, with its list
/// controls in a row just under it.
private func tableBlock(_ scrollView: NSScrollView, height: CGFloat, controls: [NSView]) -> NSView {
    let container = NSView()
    let buttons = NSStackView(views: controls)
    buttons.orientation = .horizontal
    buttons.spacing = 8
    for subview in [scrollView, buttons] as [NSView] {
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
    }
    NSLayoutConstraint.activate([
        scrollView.topAnchor.constraint(equalTo: container.topAnchor),
        scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        scrollView.widthAnchor.constraint(equalToConstant: SettingsForm.controlColumnWidth),
        scrollView.heightAnchor.constraint(equalToConstant: height),
        buttons.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
        buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
}
