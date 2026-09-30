import AppKit

/// The "Safari" pane of the Settings window: turns the ongoing Safari
/// history sync on or off (see SafariHistorySyncCoordinator) and picks which
/// browser profile each Safari profile's history goes to. Rows are keyed by
/// `SafariImportScanner.ProfileSource.id`; the display name beside it is
/// cosmetic.
/// Every change saves immediately, like the other panes.
final class SafariSyncPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    private static let tableHeight: CGFloat = 170

    private let form = SettingsForm()
    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat { form.fittingHeight }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 420))

    private let enabledCheckbox = NSButton(checkboxWithTitle: "Sync Safari history into this browser", target: nil, action: nil)
    private let accessNoticeLabel = SettingsForm.footnote()
    private let openAccessSettingsButton = NSButton(title: "Open Full Disk Access Settings…", target: nil, action: nil)
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let syncNowButton = NSButton(title: "Sync Now", target: nil, action: nil)
    /// Shown only while Safari's data can't be read.
    private var accessRows: [NSGridRow] = []

    private var safariProfiles: [SafariImportScanner.ProfileSource] = []
    /// Nil until the first discovery finishes; false when Safari's data
    /// could not be read.
    private var discoverySucceeded: Bool?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        setUpViews()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .safariHistorySyncDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.updateState()
        })
        observers.append(center.addObserver(forName: .profileManagerDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.tableView.reloadData()
        })
        updateState()
    }

    /// Re-lists Safari's profiles each time Settings opens: a profile may
    /// have been added in Safari, or Full Disk Access granted since.
    func reload() {
        updateState()
        SafariHistorySyncCoordinator.shared.discoverSafariProfiles { [weak self] profiles in
            guard let self else { return }
            self.discoverySucceeded = profiles != nil
            self.safariProfiles = profiles ?? []
            self.tableView.reloadData()
            self.updateState()
        }
    }

    private func updateState() {
        let coordinator = SafariHistorySyncCoordinator.shared
        enabledCheckbox.state = coordinator.settings.isEnabled ? .on : .off
        syncNowButton.isEnabled = coordinator.settings.isEnabled && coordinator.status != .running

        let notReadable = discoverySucceeded == false || coordinator.status == .safariNotReadable
        if accessRows.contains(where: { $0.isHidden == notReadable }) {
            accessRows.forEach { $0.isHidden = !notReadable }
            invalidateContentHeight()
        }

        switch coordinator.status {
        case _ where !coordinator.settings.isEnabled:
            statusLabel.stringValue = "Sync is off."
        case .notRunYet:
            statusLabel.stringValue = "Not synced yet."
        case .running:
            statusLabel.stringValue = "Syncing…"
        case .safariNotReadable:
            statusLabel.stringValue = "Waiting for Full Disk Access."
        case .synced(let date, let importedVisits):
            let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
            statusLabel.stringValue = "Last synced at \(time): \(importedVisits) new visit\(importedVisits == 1 ? "" : "s")."
        }
    }

    // MARK: - View setup

    private func setUpViews() {
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledToggled)
        form.addRow("History:", enabledCheckbox)
        form.addFootnote(SettingsForm.footnote("Every few minutes, new Safari history is copied into this browser, "
            + "including pages Safari synced from your other devices through iCloud. Safari's own data is only read, never changed."),
            indented: true)

        accessNoticeLabel.stringValue = "macOS protects Safari's history. To sync it, turn on Browser in "
            + "System Settings > Privacy & Security > Full Disk Access. Sync starts on its own once access is granted."
        accessNoticeLabel.textColor = .systemOrange
        openAccessSettingsButton.target = self
        openAccessSettingsButton.action = #selector(openFullDiskAccessSettings)
        accessRows = [
            form.addFootnote(accessNoticeLabel, indented: true),
            form.addRow(nil, openAccessSettingsButton),
        ]

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        syncNowButton.target = self
        syncNowButton.action = #selector(syncNow)
        form.addRow(SettingsForm.label("Status:"), [statusLabel, syncNowButton])

        form.beginSection()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: SettingsForm.controlColumnWidth),
            scrollView.heightAnchor.constraint(equalToConstant: Self.tableHeight),
        ])
        let profileColumn = NSTableColumn(identifier: .init("profile"))
        profileColumn.title = "Safari Profile"
        profileColumn.width = 210
        let destinationColumn = NSTableColumn(identifier: .init("destination"))
        destinationColumn.title = "Sync Into"
        destinationColumn.width = 160
        tableView.addTableColumn(profileColumn)
        tableView.addTableColumn(destinationColumn)
        tableView.dataSource = self
        tableView.delegate = self
        ListAppearance.apply(to: tableView, in: scrollView, rowHeight: 40)
        scrollView.documentView = tableView
        let tableRow = form.addRow("Safari profiles:", scrollView)
        tableRow.rowAlignment = .none
        tableRow.yPlacement = .top

        form.install(in: view)
    }

    // MARK: - Actions

    @objc private func enabledToggled() {
        SafariHistorySyncCoordinator.shared.setEnabled(enabledCheckbox.state == .on)
    }

    @objc private func syncNow() {
        SafariHistorySyncCoordinator.shared.syncNow()
    }

    @objc private func openFullDiskAccessSettings() {
        SafariHistorySyncCoordinator.openFullDiskAccessSettings()
    }

    @objc private func destinationChanged(_ sender: NSPopUpButton) {
        guard safariProfiles.indices.contains(sender.tag),
              let target = sender.selectedItem?.representedObject as? TargetBox else { return }
        SafariHistorySyncCoordinator.shared.setTarget(target.target, forSafariProfile: safariProfiles[sender.tag].id)
    }

    /// NSMenuItem.representedObject needs a class; the target is an enum.
    private final class TargetBox {
        let target: SafariHistorySyncTarget
        init(_ target: SafariHistorySyncTarget) { self.target = target }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        safariProfiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard safariProfiles.indices.contains(row) else { return nil }
        let safariProfile = safariProfiles[row]
        switch tableColumn?.identifier.rawValue {
        case "profile":
            let label = NSTextField(labelWithString: "")
            label.attributedStringValue = profileLabelText(for: safariProfile)
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = safariProfile.id
            return label
        case "destination":
            return destinationPopup(for: safariProfile, row: row)
        default:
            return nil
        }
    }

    private func profileLabelText(for profile: SafariImportScanner.ProfileSource) -> NSAttributedString {
        let text = NSMutableAttributedString(string: profile.displayName + "\n", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let detail = profile.historyPath == nil ? "No history on this Mac" : "Has history on this Mac"
        text.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    private func destinationPopup(for safariProfile: SafariImportScanner.ProfileSource, row: Int) -> NSPopUpButton {
        let coordinator = SafariHistorySyncCoordinator.shared
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.tag = row
        popup.target = self
        popup.action = #selector(destinationChanged(_:))

        let defaultName = coordinator.defaultDestinationProfile?.name ?? "No Profile"
        let defaultItem = NSMenuItem(title: "\(defaultName) (default)", action: nil, keyEquivalent: "")
        defaultItem.representedObject = TargetBox(.defaultProfile)
        popup.menu?.addItem(defaultItem)
        popup.menu?.addItem(.separator())

        var selected = defaultItem
        let target = coordinator.settings.target(forSafariProfile: safariProfile.id)
        for profile in ProfileManager.shared.profiles where !profile.isPrivate {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.representedObject = TargetBox(.profile(id: profile.id))
            popup.menu?.addItem(item)
            if target == .profile(id: profile.id) { selected = item }
        }

        popup.menu?.addItem(.separator())
        let skipItem = NSMenuItem(title: "Don't Sync", action: nil, keyEquivalent: "")
        skipItem.representedObject = TargetBox(.skip)
        popup.menu?.addItem(skipItem)
        if target == .skip { selected = skipItem }

        // A target whose profile was deleted resolves to the default, so
        // the popup shows that rather than a profile that no longer exists.
        popup.select(selected)
        return popup
    }
}
