import AppKit

/// The "Safari" pane of the Settings window: turns the ongoing Safari
/// history sync on or off (see SafariHistorySyncCoordinator) and picks which
/// browser profile each Safari profile's history goes to. Rows are keyed by
/// `SafariImportScanner.ProfileSource.id`; the display name beside it is
/// cosmetic.
/// Every change saves immediately, like the other panes.
final class SafariSyncPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    private static let margin: CGFloat = 12
    private static let rowGap: CGFloat = 10
    private static let headerHeight: CGFloat = 22
    private static let captionHeight: CGFloat = 44
    private static let checkboxRowHeight: CGFloat = 20
    private static let accessNoticeHeight: CGFloat = 32
    private static let buttonRowHeight: CGFloat = 28
    private static let sectionLabelHeight: CGFloat = 16
    private static let tableHeight: CGFloat = 170

    /// Computed bottom-up from the same constants setUpViews lays out with
    /// top-down: header, caption, checkbox, the Full Disk Access notice and
    /// its button, the profiles section, and the status row.
    static let preferredContentHeight: CGFloat =
        margin + headerHeight + rowGap + captionHeight + rowGap + checkboxRowHeight
            + rowGap + accessNoticeHeight + 4 + buttonRowHeight
            + rowGap + sectionLabelHeight + 4 + tableHeight + rowGap + buttonRowHeight + margin
    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat { Self.preferredContentHeight }

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: SafariSyncPaneController.preferredContentHeight))

    private let enabledCheckbox = NSButton(checkboxWithTitle: "Sync Safari history into this browser", target: nil, action: nil)
    private let accessNoticeLabel = NSTextField(wrappingLabelWithString: "")
    private let openAccessSettingsButton = NSButton(title: "Open Full Disk Access Settings…", target: nil, action: nil)
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let syncNowButton = NSButton(title: "Sync Now", target: nil, action: nil)

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
        accessNoticeLabel.isHidden = !notReadable
        openAccessSettingsButton.isHidden = !notReadable

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
        let margin = Self.margin
        let rowGap = Self.rowGap
        let width = view.bounds.width - margin * 2

        let headerLabel = NSTextField(labelWithString: "Safari History Sync")
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.frame = NSRect(x: margin, y: view.bounds.height - margin - Self.headerHeight, width: width, height: Self.headerHeight)
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        let captionY = headerLabel.frame.minY - rowGap - Self.captionHeight
        let captionLabel = NSTextField(wrappingLabelWithString: "Every few minutes, new Safari history is copied into this browser, "
            + "including pages Safari synced from your other devices through iCloud. Safari's own data is only read, never changed.")
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.frame = NSRect(x: margin, y: captionY, width: width, height: Self.captionHeight)
        captionLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(captionLabel)

        let checkboxY = captionY - rowGap - Self.checkboxRowHeight
        enabledCheckbox.target = self
        enabledCheckbox.action = #selector(enabledToggled)
        enabledCheckbox.frame = NSRect(x: margin, y: checkboxY, width: width, height: Self.checkboxRowHeight)
        enabledCheckbox.autoresizingMask = [.width, .minYMargin]
        view.addSubview(enabledCheckbox)

        let noticeY = checkboxY - rowGap - Self.accessNoticeHeight
        accessNoticeLabel.stringValue = "macOS protects Safari's history. To sync it, turn on Browser in "
            + "System Settings > Privacy & Security > Full Disk Access. Sync starts on its own once access is granted."
        accessNoticeLabel.font = .systemFont(ofSize: 11)
        accessNoticeLabel.textColor = .systemOrange
        accessNoticeLabel.frame = NSRect(x: margin, y: noticeY, width: width, height: Self.accessNoticeHeight)
        accessNoticeLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(accessNoticeLabel)

        let accessButtonY = noticeY - 4 - Self.buttonRowHeight
        openAccessSettingsButton.target = self
        openAccessSettingsButton.action = #selector(openFullDiskAccessSettings)
        openAccessSettingsButton.frame = NSRect(x: margin, y: accessButtonY, width: 240, height: Self.buttonRowHeight)
        openAccessSettingsButton.autoresizingMask = [.maxXMargin, .minYMargin]
        view.addSubview(openAccessSettingsButton)

        let sectionY = accessButtonY - rowGap - Self.sectionLabelHeight
        let sectionLabel = NSTextField(labelWithString: "Safari Profiles")
        sectionLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sectionLabel.textColor = .secondaryLabelColor
        sectionLabel.frame = NSRect(x: margin, y: sectionY, width: width, height: Self.sectionLabelHeight)
        sectionLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(sectionLabel)

        // Bottom row: status on the left, Sync Now on the right.
        let syncNowWidth: CGFloat = 100
        syncNowButton.target = self
        syncNowButton.action = #selector(syncNow)
        syncNowButton.frame = NSRect(x: view.bounds.width - margin - syncNowWidth, y: margin, width: syncNowWidth, height: Self.buttonRowHeight)
        syncNowButton.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(syncNowButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: margin, y: margin + 6, width: width - syncNowWidth - 8, height: 16)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(statusLabel)

        // The table fills the space between its header and the bottom row.
        let tableTop = sectionY - 4
        let tableBottom = margin + Self.buttonRowHeight + rowGap
        let scrollView = NSScrollView(frame: NSRect(x: margin, y: tableBottom, width: width, height: tableTop - tableBottom))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let profileColumn = NSTableColumn(identifier: .init("profile"))
        profileColumn.title = "Safari Profile"
        profileColumn.width = 280
        let destinationColumn = NSTableColumn(identifier: .init("destination"))
        destinationColumn.title = "Sync Into"
        destinationColumn.width = 220
        tableView.addTableColumn(profileColumn)
        tableView.addTableColumn(destinationColumn)
        tableView.dataSource = self
        tableView.delegate = self
        ListAppearance.apply(to: tableView, in: scrollView, rowHeight: 40)
        scrollView.documentView = tableView
        view.addSubview(scrollView)
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
