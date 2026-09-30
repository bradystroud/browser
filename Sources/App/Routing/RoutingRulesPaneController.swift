import AppKit

/// The "Routing Rules" pane of the Settings window (see
/// SettingsWindowController, which hosts this alongside ProfilesPaneController
/// in an NSTabView). An ordered table of rules (first match wins, see
/// RuleMatcher), add/edit/delete, up/down reordering, a default-profile
/// picker for links no rule matches, a "Test" affordance (browser-ymx: paste
/// a URL, optionally pick a source app, see which rule -- if any -- would
/// match and which profile it resolves to), and a "Make Default Browser…"
/// button. Every mutation saves immediately via RoutingRulesStore -- there
/// is no separate "Apply" step; only "Make Default Browser…" has an
/// explicit action, since that one triggers a system confirmation dialog
/// rather than just writing local state.
final class RoutingRulesPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let tableView = NSTableView()
    private let defaultProfilePopup = NSPopUpButton()
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
    private let testResultLabel = NSTextField(wrappingLabelWithString: "")

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
    }

    // MARK: - View setup

    /// Bottom-up layout (AppKit's y-axis): "Make Default Browser…" at the
    /// very bottom, then the default-profile picker, then the rule
    /// add/edit/reorder controls, then the rules table filling the rest,
    /// with a "Routing Rules" section header pinned to the top.
    private func setUpViews() {
        let margin: CGFloat = 12
        let rowGap: CGFloat = 10
        let headerHeight: CGFloat = 22
        let makeDefaultRowHeight: CGFloat = 28
        let defaultRowHeight: CGFloat = 32
        let buttonRowHeight: CGFloat = 28

        let makeDefaultBrowserButton = NSButton(
            title: "Make Default Browser…",
            target: self,
            action: #selector(makeDefaultBrowserClicked)
        )
        makeDefaultBrowserButton.bezelStyle = .rounded
        makeDefaultBrowserButton.frame = NSRect(x: margin, y: margin, width: 190, height: makeDefaultRowHeight)
        makeDefaultBrowserButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(makeDefaultBrowserButton)

        let defaultRowY = margin + makeDefaultRowHeight + rowGap
        let defaultLabel = NSTextField(labelWithString: "Unmatched links, no window open:")
        defaultLabel.frame = NSRect(x: margin, y: defaultRowY + 6, width: 230, height: 20)
        defaultLabel.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(defaultLabel)

        defaultProfilePopup.frame = NSRect(x: margin + 234, y: defaultRowY, width: 200, height: 28)
        defaultProfilePopup.autoresizingMask = [.minXMargin, .maxYMargin]
        defaultProfilePopup.target = self
        defaultProfilePopup.action = #selector(defaultProfileChanged)
        view.addSubview(defaultProfilePopup)

        let buttonRowY = defaultRowY + defaultRowHeight + rowGap
        let addButton = NSButton(title: "＋", target: self, action: #selector(addRule))
        addButton.frame = NSRect(x: margin, y: buttonRowY, width: 32, height: buttonRowHeight)
        addButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(addButton)

        let removeButton = NSButton(title: "－", target: self, action: #selector(removeSelectedRule))
        removeButton.frame = NSRect(x: margin + 34, y: buttonRowY, width: 32, height: buttonRowHeight)
        removeButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(removeButton)

        let editButton = NSButton(title: "Edit…", target: self, action: #selector(editSelectedRule))
        editButton.frame = NSRect(x: margin + 74, y: buttonRowY, width: 60, height: buttonRowHeight)
        editButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(editButton)

        let upButton = NSButton(title: "▲", target: self, action: #selector(moveSelectedRuleUp))
        upButton.frame = NSRect(x: view.bounds.width - margin - 68, y: buttonRowY, width: 32, height: buttonRowHeight)
        upButton.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(upButton)

        let downButton = NSButton(title: "▼", target: self, action: #selector(moveSelectedRuleDown))
        downButton.frame = NSRect(x: view.bounds.width - margin - 34, y: buttonRowY, width: 32, height: buttonRowHeight)
        downButton.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(downButton)

        let headerLabel = NSTextField(labelWithString: "Routing Rules")
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.frame = NSRect(
            x: margin,
            y: view.bounds.height - margin - headerHeight,
            width: view.bounds.width - margin * 2,
            height: headerHeight
        )
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        // Test affordance -- a fixed-height strip between the add/edit/
        // reorder button row and the rules table, so it's visible without
        // scrolling regardless of how many rules exist.
        let testRowHeight: CGFloat = 24
        let testResultHeight: CGFloat = 32
        let testSectionY = buttonRowY + buttonRowHeight + rowGap
        let testButtonWidth: CGFloat = 60
        let testSourceWidth: CGFloat = 150

        testURLField.placeholderString = "Paste a URL to test…"
        testURLField.frame = NSRect(
            x: margin,
            y: testSectionY + testResultHeight + 4,
            width: view.bounds.width - margin * 2 - testSourceWidth - testButtonWidth - 8,
            height: testRowHeight
        )
        testURLField.autoresizingMask = [.width, .minYMargin]
        view.addSubview(testURLField)

        testSourceAppPopup.frame = NSRect(
            x: view.bounds.width - margin - testSourceWidth - testButtonWidth - 4,
            y: testSectionY + testResultHeight + 4,
            width: testSourceWidth,
            height: testRowHeight
        )
        testSourceAppPopup.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(testSourceAppPopup)

        let testButton = NSButton(title: "Test", target: self, action: #selector(runTest))
        testButton.frame = NSRect(
            x: view.bounds.width - margin - testButtonWidth,
            y: testSectionY + testResultHeight + 4,
            width: testButtonWidth,
            height: testRowHeight
        )
        testButton.autoresizingMask = [.minXMargin, .minYMargin]
        view.addSubview(testButton)

        testResultLabel.font = .systemFont(ofSize: 11)
        testResultLabel.textColor = .secondaryLabelColor
        testResultLabel.frame = NSRect(x: margin, y: testSectionY, width: view.bounds.width - margin * 2, height: testResultHeight)
        testResultLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(testResultLabel)

        reloadTestSourceAppPopup()

        let scrollViewY = testSectionY + testResultHeight + testRowHeight + 4 + rowGap
        let scrollView = NSScrollView(frame: NSRect(
            x: margin,
            y: scrollViewY,
            width: view.bounds.width - margin * 2,
            height: view.bounds.height - margin - headerHeight - scrollViewY
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

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
        tableView.doubleAction = #selector(editSelectedRule)
        tableView.target = self
        ListAppearance.apply(to: tableView, in: scrollView)
        scrollView.documentView = tableView
        view.addSubview(scrollView)
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

        testResultLabel.stringValue = lines.joined(separator: "\n")
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

        return ListAppearance.textCell(in: tableView, identifier: "cell", text: text, lineBreakMode: .byTruncatingTail)
    }
}
