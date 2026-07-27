import AppKit

/// "Routing Rules…" settings window: an ordered table of rules (first match
/// wins, see RuleMatcher), add/edit/delete, up/down reordering, and a
/// default-profile picker for links no rule matches. Every mutation saves
/// immediately via RoutingRulesStore -- there is no separate "Apply" step.
final class RoutingRulesWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = RoutingRulesWindowController()

    private let tableView = NSTableView()
    private let defaultProfilePopup = NSPopUpButton()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Routing Rules"
        window.center()
        super.init(window: window)
        window.delegate = self
        setUpViews()
        reloadTable()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        reloadTable()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - View setup

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }
        let margin: CGFloat = 12
        let buttonRowHeight: CGFloat = 28
        let defaultRowHeight: CGFloat = 32

        let scrollView = NSScrollView(frame: NSRect(
            x: margin,
            y: margin + buttonRowHeight + defaultRowHeight,
            width: contentView.bounds.width - margin * 2,
            height: contentView.bounds.height - margin * 2 - buttonRowHeight - defaultRowHeight
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let matchColumn = NSTableColumn(identifier: .init("match"))
        matchColumn.title = "Match (first match wins)"
        matchColumn.width = 340
        let profileColumn = NSTableColumn(identifier: .init("profile"))
        profileColumn.title = "Profile"
        profileColumn.width = 140

        tableView.addTableColumn(matchColumn)
        tableView.addTableColumn(profileColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(editSelectedRule)
        tableView.target = self
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        let buttonRowY = margin + defaultRowHeight
        let addButton = NSButton(title: "＋", target: self, action: #selector(addRule))
        addButton.frame = NSRect(x: margin, y: buttonRowY, width: 32, height: buttonRowHeight)
        addButton.autoresizingMask = [.maxXMargin]
        contentView.addSubview(addButton)

        let removeButton = NSButton(title: "－", target: self, action: #selector(removeSelectedRule))
        removeButton.frame = NSRect(x: margin + 34, y: buttonRowY, width: 32, height: buttonRowHeight)
        removeButton.autoresizingMask = [.maxXMargin]
        contentView.addSubview(removeButton)

        let editButton = NSButton(title: "Edit…", target: self, action: #selector(editSelectedRule))
        editButton.frame = NSRect(x: margin + 74, y: buttonRowY, width: 60, height: buttonRowHeight)
        editButton.autoresizingMask = [.maxXMargin]
        contentView.addSubview(editButton)

        let upButton = NSButton(title: "▲", target: self, action: #selector(moveSelectedRuleUp))
        upButton.frame = NSRect(x: contentView.bounds.width - margin - 68, y: buttonRowY, width: 32, height: buttonRowHeight)
        upButton.autoresizingMask = [.minXMargin]
        contentView.addSubview(upButton)

        let downButton = NSButton(title: "▼", target: self, action: #selector(moveSelectedRuleDown))
        downButton.frame = NSRect(x: contentView.bounds.width - margin - 34, y: buttonRowY, width: 32, height: buttonRowHeight)
        downButton.autoresizingMask = [.minXMargin]
        contentView.addSubview(downButton)

        let defaultLabel = NSTextField(labelWithString: "Default profile for unmatched links:")
        defaultLabel.frame = NSRect(x: margin, y: margin + 6, width: 230, height: 20)
        defaultLabel.autoresizingMask = [.maxXMargin]
        contentView.addSubview(defaultLabel)

        defaultProfilePopup.frame = NSRect(x: margin + 234, y: margin, width: 200, height: 28)
        defaultProfilePopup.autoresizingMask = [.minXMargin]
        defaultProfilePopup.target = self
        defaultProfilePopup.action = #selector(defaultProfileChanged)
        contentView.addSubview(defaultProfilePopup)
    }

    // MARK: - Data

    private func reloadTable() {
        tableView.reloadData()
        reloadDefaultProfilePopup()
    }

    private func reloadDefaultProfilePopup() {
        defaultProfilePopup.removeAllItems()
        let profiles = ProfileManager.shared.profiles
        for profile in profiles {
            let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
            item.representedObject = profile
            defaultProfilePopup.menu?.addItem(item)
        }
        if let index = profiles.firstIndex(where: { $0.id == RoutingRulesStore.shared.defaultProfileId }) {
            defaultProfilePopup.selectItem(at: index)
        }
    }

    private func matchSummary(for match: RoutingRule.Match) -> String {
        var parts: [String] = []
        if let domainGlob = match.domainGlob { parts.append("domain: \(domainGlob)") }
        if let urlRegex = match.urlRegex { parts.append("regex: \(urlRegex)") }
        if let sourceBundleIds = match.sourceBundleIds, !sourceBundleIds.isEmpty {
            parts.append("source: \(sourceBundleIds.joined(separator: ", "))")
        }
        return parts.isEmpty ? "(matches every link)" : parts.joined(separator: "  AND  ")
    }

    // MARK: - Actions

    @objc private func addRule() {
        guard !ProfileManager.shared.profiles.isEmpty else { return }
        guard let rule = RoutingRuleEditor.run(existingRule: nil) else { return }
        RoutingRulesStore.shared.addRule(rule)
        reloadTable()
    }

    @objc private func editSelectedRule() {
        let index = tableView.selectedRow
        guard RoutingRulesStore.shared.rules.indices.contains(index) else { return }
        let existing = RoutingRulesStore.shared.rules[index]
        guard let edited = RoutingRuleEditor.run(existingRule: existing) else { return }
        RoutingRulesStore.shared.updateRule(edited)
        reloadTable()
    }

    @objc private func removeSelectedRule() {
        let index = tableView.selectedRow
        guard RoutingRulesStore.shared.rules.indices.contains(index) else { return }
        RoutingRulesStore.shared.deleteRule(id: RoutingRulesStore.shared.rules[index].id)
        reloadTable()
    }

    @objc private func moveSelectedRuleUp() {
        let index = tableView.selectedRow
        guard index > 0 else { return }
        RoutingRulesStore.shared.moveRule(at: index, by: -1)
        reloadTable()
        tableView.selectRowIndexes([index - 1], byExtendingSelection: false)
    }

    @objc private func moveSelectedRuleDown() {
        let index = tableView.selectedRow
        guard RoutingRulesStore.shared.rules.indices.contains(index) else { return }
        RoutingRulesStore.shared.moveRule(at: index, by: 1)
        reloadTable()
        tableView.selectRowIndexes([index + 1], byExtendingSelection: false)
    }

    @objc private func defaultProfileChanged() {
        guard let profile = defaultProfilePopup.selectedItem?.representedObject as? Profile else { return }
        RoutingRulesStore.shared.setDefaultProfileId(profile.id)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        RoutingRulesStore.shared.rules.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard RoutingRulesStore.shared.rules.indices.contains(row) else { return nil }
        let rule = RoutingRulesStore.shared.rules[row]

        let text: String
        switch tableColumn?.identifier.rawValue {
        case "match":
            text = matchSummary(for: rule.match)
        case "profile":
            text = ProfileManager.shared.profile(id: rule.action.profileId)?.name ?? "(unknown profile)"
        default:
            text = ""
        }

        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = text
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down -- this is a singleton, kept alive for the
        // app's lifetime, just hidden when closed.
    }
}
