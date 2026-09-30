import AppKit

/// The "Links" pane of the Settings window (see SettingsWindowController).
/// An ordered table of link rules (first match wins, see RuleMatcher) with
/// add/remove/reorder under it and Edit… beside them, then the profile for
/// links no rule matches, the little-window preference, a "Test" affordance
/// (browser-ymx: paste a URL, optionally pick a source app, see which rule
/// -- if any -- would match and which profile it resolves to), and a "Make
/// Default Browser…" button. Every mutation saves immediately via
/// RoutingRulesStore -- there is no separate "Apply" step; only "Make
/// Default Browser…" has an explicit action, since that one triggers a
/// system confirmation dialog rather than just writing local state.
final class RoutingRulesPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    /// The rules table's height when the window is fitted to this pane; it
    /// grows with the window and never shrinks below `minimumTableHeight`.
    private static let preferredTableHeight: CGFloat = 200
    private static let minimumTableHeight: CGFloat = 120

    private static let upSegment = 2
    private static let downSegment = 3

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 600))

    private let tableView = NSTableView()
    private let tableScrollView = NSScrollView()
    private let listButtons = SettingsListButtons(
        target: nil,
        action: nil,
        extraSymbols: [("chevron.up", "Move Up"), ("chevron.down", "Move Down")]
    )
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let form = SettingsForm()
    private let defaultProfilePopup = NSPopUpButton()
    private let littleWindowCheckbox = NSButton(
        checkboxWithTitle: "Open links from other apps in a little window",
        target: nil,
        action: nil
    )
    private let makeDefaultBrowserButton = NSButton(title: "Make Default Browser…", target: nil, action: nil)
    private var profileChangeObserver: NSObjectProtocol?

    /// "Test" affordance (browser-ymx): Brady pastes a URL (and optionally
    /// picks a source app) and sees which rule would match, or that none
    /// would -- twice now, a rule has silently not matched and it cost him
    /// real time tracking down why. Evaluates via
    /// RuleMatcher.evaluate(context:rules:defaultProfileId:), the same
    /// shared entry point the `browser route-test` CLI command uses, so
    /// this pane and the CLI can never disagree about which rule matched.
    private let testURLField = NSTextField(string: "")
    private let testSourceAppPopup = NSPopUpButton()
    private let testButton = NSButton(title: "Test", target: nil, action: nil)
    private let testResultLabel = SettingsForm.footnote()

    override init() {
        super.init()
        setUpViews()
        reload()
        // A profile can be renamed/recolored/deleted from the Profiles pane
        // while this pane is showing stale profile names in its table and
        // popup -- refresh on any ProfileManager change regardless of source.
        profileChangeObserver = NotificationCenter.default.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    func reload() {
        tableView.reloadData()
        reloadDefaultProfilePopup()
        littleWindowCheckbox.state = LinkHandlingPreferences.littleWindowForExternalLinks ? .on : .off
        updateListButtons()
    }

    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat {
        let margin = SettingsForm.margin
        return (margin + Self.preferredTableHeight + listButtons.fittingSize.height
            + SettingsForm.sectionSpacing + form.grid.fittingSize.height + margin).rounded(.up)
    }

    // MARK: - View setup

    /// Top-down: the rules table (stretching with the window) with its
    /// add/remove/reorder control flush under it and Edit… at its right,
    /// then a form of the pane's other settings.
    private func setUpViews() {
        let matchColumn = NSTableColumn(identifier: .init("match"))
        matchColumn.title = "Match (first match wins)"
        matchColumn.width = 440
        let profileColumn = NSTableColumn(identifier: .init("profile"))
        profileColumn.title = "Profile"
        profileColumn.width = 160

        tableView.addTableColumn(matchColumn)
        tableView.addTableColumn(profileColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(editSelectedRule)
        tableView.target = self
        tableScrollView.hasVerticalScroller = true
        ListAppearance.apply(to: tableView, in: tableScrollView)
        tableScrollView.documentView = tableView

        listButtons.target = self
        listButtons.action = #selector(listButtonClicked)

        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        editButton.target = self
        editButton.action = #selector(editSelectedRule)

        defaultProfilePopup.target = self
        defaultProfilePopup.action = #selector(defaultProfileChanged)
        form.addRow("Unmatched links open in:", defaultProfilePopup)
        form.addFootnote(SettingsForm.footnote(
            "When no window is open. Otherwise they open in the frontmost window\u{2019}s profile."))

        // A rule's own "Open in" overrides this in either direction.
        littleWindowCheckbox.target = self
        littleWindowCheckbox.action = #selector(littleWindowToggled)
        form.addRow(nil, littleWindowCheckbox)

        form.beginSection()
        testURLField.placeholderString = "Paste a URL to test…"
        testURLField.target = self
        testURLField.action = #selector(runTest)
        form.addFillingRow("Test a link:", testURLField)
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(runTest)
        form.addRow(SettingsForm.label("From:"), [testSourceAppPopup, testButton])
        form.addFootnote(testResultLabel)
        reloadTestSourceAppPopup()

        form.beginSection()
        makeDefaultBrowserButton.bezelStyle = .rounded
        makeDefaultBrowserButton.target = self
        makeDefaultBrowserButton.action = #selector(makeDefaultBrowserClicked)
        form.addRow("Default browser:", makeDefaultBrowserButton)

        for subview in [tableScrollView, listButtons, editButton, form.grid] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let margin = SettingsForm.margin
        let fillBottom = form.grid.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin)
        // Gives way rather than squeezing the table below its minimum while
        // the pane is still at its initial, pre-fit size.
        fillBottom.priority = .init(999)
        NSLayoutConstraint.activate([
            tableScrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            tableScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            tableScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            tableScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumTableHeight),
            listButtons.topAnchor.constraint(equalTo: tableScrollView.bottomAnchor),
            listButtons.leadingAnchor.constraint(equalTo: tableScrollView.leadingAnchor),
            editButton.centerYAnchor.constraint(equalTo: listButtons.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: tableScrollView.trailingAnchor),
            form.grid.topAnchor.constraint(equalTo: listButtons.bottomAnchor, constant: SettingsForm.sectionSpacing),
            form.grid.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            fillBottom,
        ])

        // Reading order, looping back to the table.
        tableView.nextKeyView = listButtons
        listButtons.nextKeyView = editButton
        editButton.nextKeyView = defaultProfilePopup
        defaultProfilePopup.nextKeyView = littleWindowCheckbox
        littleWindowCheckbox.nextKeyView = testURLField
        testURLField.nextKeyView = testSourceAppPopup
        testSourceAppPopup.nextKeyView = testButton
        testButton.nextKeyView = makeDefaultBrowserButton
        makeDefaultBrowserButton.nextKeyView = tableView
    }

    @objc private func listButtonClicked() {
        switch listButtons.selectedSegment {
        case SettingsListButtons.addSegment: addRule()
        case SettingsListButtons.removeSegment: removeSelectedRule()
        case Self.upSegment: moveSelectedRuleUp()
        case Self.downSegment: moveSelectedRuleDown()
        default: break
        }
    }

    private func updateListButtons() {
        let index = tableView.selectedRow
        let count = RoutingRulesStore.shared.rules.count
        let hasSelection = index >= 0 && index < count
        listButtons.canRemove = hasSelection
        listButtons.setEnabled(hasSelection && index > 0, forSegment: Self.upSegment)
        listButtons.setEnabled(hasSelection && index < count - 1, forSegment: Self.downSegment)
        editButton.isEnabled = hasSelection
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateListButtons()
    }

    /// Only "http" matters for default-browser purposes (see
    /// docs/research/2026-07-27-link-routing-macos.md); macOS always shows
    /// its own native confirmation dialog here and it cannot be
    /// skipped/pre-approved, and only fires correctly for a properly
    /// installed, Developer-ID-signed app bundle -- invoked from a raw
    /// build/ directory it may silently no-op or misbehave, which is
    /// acceptable for local dev (see docs/ai-tasks/m2-routing-notes.md).
    @objc private func makeDefaultBrowserClicked() {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { error in
            if let error {
                NSLog("Browser: setDefaultApplication(toOpenURLsWithScheme: \"http\") failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Data

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
        if let urlContains = match.urlContains { parts.append("contains: \(urlContains)") }
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
        reload()
    }

    @objc private func editSelectedRule() {
        let index = tableView.selectedRow
        guard RoutingRulesStore.shared.rules.indices.contains(index) else { return }
        let existing = RoutingRulesStore.shared.rules[index]
        guard let edited = RoutingRuleEditor.run(existingRule: existing) else { return }
        RoutingRulesStore.shared.updateRule(edited)
        reload()
    }

    @objc private func removeSelectedRule() {
        let index = tableView.selectedRow
        guard RoutingRulesStore.shared.rules.indices.contains(index) else { return }
        RoutingRulesStore.shared.deleteRule(id: RoutingRulesStore.shared.rules[index].id)
        reload()
    }

    @objc private func moveSelectedRuleUp() {
        let index = tableView.selectedRow
        guard index > 0 else { return }
        RoutingRulesStore.shared.moveRule(at: index, by: -1)
        reload()
        tableView.selectRowIndexes([index - 1], byExtendingSelection: false)
    }

    @objc private func moveSelectedRuleDown() {
        let index = tableView.selectedRow
        guard RoutingRulesStore.shared.rules.indices.contains(index) else { return }
        RoutingRulesStore.shared.moveRule(at: index, by: 1)
        reload()
        tableView.selectRowIndexes([index + 1], byExtendingSelection: false)
    }

    @objc private func littleWindowToggled() {
        LinkHandlingPreferences.littleWindowForExternalLinks = littleWindowCheckbox.state == .on
    }

    @objc private func defaultProfileChanged() {
        guard let profile = defaultProfilePopup.selectedItem?.representedObject as? Profile else { return }
        RoutingRulesStore.shared.setDefaultProfileId(profile.id)
    }

    private func reloadTestSourceAppPopup() {
        testSourceAppPopup.removeAllItems()
        testSourceAppPopup.menu?.addItem(NSMenuItem(title: "(no source app)", action: nil, keyEquivalent: ""))
        for entry in RunningApplicationPicker.currentEntries() {
            let item = NSMenuItem(title: entry.displayName, action: nil, keyEquivalent: "")
            item.representedObject = entry.bundleIdentifier
            testSourceAppPopup.menu?.addItem(item)
        }
    }

    /// Evaluates the pasted URL against the exact same
    /// RuleMatcher.evaluate(context:rules:defaultProfileId:) entry point
    /// RoutingCoordinator.route(url:sourceBundleId:) and the `browser
    /// route-test` CLI command both use -- see testURLField's own doc
    /// comment for why sharing this one function matters. Applies tracking-
    /// param stripping first if that preference is on, matching what a real
    /// routed link would see before it's ever matched; deliberately does
    /// NOT perform a live un-shortening network call here (this stays pure
    /// and synchronous), just a note that one would happen for a link that
    /// looks shortened.
    @objc private func runTest() {
        let rawURL = testURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            testResultLabel.stringValue = ""
            tableView.deselectAll(nil)
            invalidateContentHeight()
            return
        }

        let url = LinkHandlingPreferences.stripTrackingParams ? TrackingParamStripper.strip(rawURL) : rawURL
        let sourceBundleId = testSourceAppPopup.selectedItem?.representedObject as? String

        let store = RoutingRulesStore.shared
        let context = RoutingContext(url: url, sourceBundleId: sourceBundleId)
        let evaluation = RuleMatcher.evaluate(context: context, rules: store.rules, defaultProfileId: store.defaultProfileId)

        var lines: [String] = []
        if url != rawURL {
            lines.append("Tracking parameters stripped before matching: \(url)")
        }
        if LinkHandlingPreferences.unshortenLinks, URLUnshortener.isLikelyShortened(url) {
            lines.append("This looks like a shortened link -- opening it for real would follow it to its destination first, which may change which rule matches.")
        }

        switch evaluation {
        case .matched(let rule, let profileId):
            let profileName = ProfileManager.shared.profile(id: profileId)?.name ?? "(unknown profile)"
            lines.append("Matched rule: \(matchSummary(for: rule.match)) → opens in \u{201C}\(profileName)\u{201D}")
            if let index = store.rules.firstIndex(where: { $0.id == rule.id }) {
                tableView.selectRowIndexes([index], byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
            }
        case .noMatch(let defaultProfileId):
            let profileName = ProfileManager.shared.profile(id: defaultProfileId)?.name ?? "(unknown profile)"
            lines.append("No rule matched → the frontmost window, or \u{201C}\(profileName)\u{201D} if no window is open")
            tableView.deselectAll(nil)
        }

        let opening = LinkOpening.resolve(
            evaluation: evaluation,
            preferLittleWindowForExternalLinks: LinkHandlingPreferences.littleWindowForExternalLinks
        )
        if opening.openIn == .littleWindow {
            lines.append("From another app, this opens in a little window.")
        }

        testResultLabel.stringValue = lines.joined(separator: "\n")
        invalidateContentHeight()
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
            let name = ProfileManager.shared.profile(id: rule.action.profileId)?.name ?? "(unknown profile)"
            switch rule.action.openIn {
            case .littleWindow: text = "\(name) · little window"
            case .browser: text = "\(name) · browser"
            case nil: text = name
            }
        default:
            text = ""
        }

        return ListAppearance.textCell(in: tableView, identifier: "cell", text: text, lineBreakMode: .byTruncatingTail)
    }
}
