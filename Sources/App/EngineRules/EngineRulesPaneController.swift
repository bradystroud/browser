import AppKit

/// The "Engines" pane of the Settings window: which engine each site opens
/// in. The user's own rules first, then the built-in ones (DRM streaming
/// sites, sent to WebKit), each with a checkbox. Built-ins can be switched
/// off but not edited or removed; the user's own can be edited in place --
/// the site by double-clicking it, the engine from its popup.
///
/// The default engine for everything else is in the General pane.
final class EngineRulesPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, SettingsPaneController {
    static let topMargin: CGFloat = 20

    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))

    private let tableView = NSTableView()
    private lazy var listButtons = SettingsListButtons(target: self, action: #selector(listButtonClicked))
    private let form = SettingsForm()
    private let helpLabel = SettingsForm.footnote(
        "A rule sends a site and its subdomains to an engine. Add a path to narrow it, as in amazon.com/gp/video. The first rule that matches wins, and your own rules come before the built-in ones. A page that follows a link off a ruled site stays in that site\u{2019}s engine, so sign-in and checkout pages keep their cookies.")

    private var rules: [EngineSiteRule] = []
    private var observer: NSObjectProtocol?

    private enum Column {
        static let enabled = NSUserInterfaceItemIdentifier("enabled")
        static let site = NSUserInterfaceItemIdentifier("site")
        static let engine = NSUserInterfaceItemIdentifier("engine")
        static let kind = NSUserInterfaceItemIdentifier("kind")
    }

    func preferredContentHeight(forWidth width: CGFloat) -> CGFloat {
        SettingsTablePane.preferredHeight(form: form, topMargin: Self.topMargin)
    }

    override init() {
        super.init()
        setUpViews()
        reload()
        observer = NotificationCenter.default.addObserver(forName: .engineRulesDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    func reload() {
        rules = EngineRulesStore.shared.effectiveRules
        tableView.reloadData()
        updateButtons()
    }

    private func setUpViews() {
        helpLabel.preferredMaxLayoutWidth = 560
        form.addSpanningRow(helpLabel)

        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Column.enabled, "On", 34),
            (Column.site, "Site", 300),
            (Column.engine, "Engine", 120),
            (Column.kind, "", 90),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self

        SettingsTablePane.install(
            in: view,
            topMargin: Self.topMargin,
            form: form,
            table: tableView,
            listButtons: listButtons,
            trailingButtons: []
        )
    }

    private func updateButtons() {
        let row = tableView.selectedRow
        listButtons.canRemove = rules.indices.contains(row) && !BuiltInEngineRules.isBuiltIn(rules[row].id)
    }

    // MARK: - Actions

    @objc private func listButtonClicked() {
        switch listButtons.selectedSegment {
        case SettingsListButtons.addSegment: addRule()
        case SettingsListButtons.removeSegment: removeSelectedRule()
        default: break
        }
    }

    /// A new rule sends a site to the engine that isn't the default --
    /// the only reason to write one -- and opens its site for typing.
    private func addRule() {
        let engine = CommandLineArgs.defaultEngine().other
        let rule = EngineSiteRule(pattern: "example.com", engine: engine.siteEngine)
        EngineRulesStore.shared.addRule(rule)
        guard let row = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.editColumn(tableView.column(withIdentifier: Column.site), row: row, with: nil, select: true)
    }

    private func removeSelectedRule() {
        let row = tableView.selectedRow
        guard rules.indices.contains(row), !BuiltInEngineRules.isBuiltIn(rules[row].id) else { return }
        EngineRulesStore.shared.deleteRule(id: rules[row].id)
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard rules.indices.contains(row), !BuiltInEngineRules.isBuiltIn(rules[row].id) else { return }
        tableView.editColumn(tableView.column(withIdentifier: Column.site), row: row, with: nil, select: true)
    }

    @objc private func enabledToggled(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard rules.indices.contains(row) else { return }
        var rule = rules[row]
        rule.isEnabled = sender.state == .on
        EngineRulesStore.shared.updateRule(rule)
    }

    @objc private func engineChosen(_ sender: NSPopUpButton) {
        let row = tableView.row(for: sender)
        guard rules.indices.contains(row),
              let raw = sender.selectedItem?.representedObject as? String,
              let engine = SiteEngine(rawValue: raw)
        else { return }
        var rule = rules[row]
        rule.engine = engine
        EngineRulesStore.shared.updateRule(rule)
    }

    /// A site that doesn't parse is refused, and the old one put back.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        guard rules.indices.contains(row) else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard EngineSitePattern(text) != nil else {
            NSSound.beep()
            field.stringValue = rules[row].pattern
            return
        }
        var rule = rules[row]
        rule.pattern = text
        EngineRulesStore.shared.updateRule(rule)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        rules.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rules.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let rule = rules[row]
        let isBuiltIn = BuiltInEngineRules.isBuiltIn(rule.id)
        switch identifier {
        case Column.enabled:
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(enabledToggled(_:)))
            checkbox.state = rule.isEnabled ? .on : .off
            checkbox.setAccessibilityLabel("Use the rule for \(rule.pattern)")
            return checkbox
        case Column.site:
            let field = ListAppearance.textCell(in: tableView, identifier: "engineRule.site", text: rule.pattern)
            field.isEditable = !isBuiltIn
            field.delegate = self
            return field
        case Column.engine:
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            for engine in EngineChoice.allCases {
                let item = NSMenuItem(title: engine.displayName, action: nil, keyEquivalent: "")
                item.representedObject = engine.rawValue
                popup.menu?.addItem(item)
            }
            popup.selectItem(at: EngineChoice.allCases.firstIndex(of: EngineChoice(rule.engine)) ?? 0)
            popup.isEnabled = !isBuiltIn
            popup.target = self
            popup.action = #selector(engineChosen(_:))
            return popup
        case Column.kind:
            return ListAppearance.textCell(in: tableView, identifier: "engineRule.kind", text: isBuiltIn ? "Built-in" : "")
        default:
            return nil
        }
    }
}
