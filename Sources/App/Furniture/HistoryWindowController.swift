import AppKit

/// "Show All History…" (⌘Y) -- a simple per-profile search + delete window,
/// backed by HistoryStore.
final class HistoryWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let profile: Profile
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private var entries: [HistoryEntry] = []

    init(profile: Profile) {
        self.profile = profile
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "History — \(profile.name)"
        window.center()
        super.init(window: window)
        window.delegate = self
        setUpViews()
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }
        let margin: CGFloat = 12
        let buttonRowHeight: CGFloat = 28
        let searchHeight: CGFloat = 24

        searchField.frame = NSRect(
            x: margin,
            y: contentView.bounds.height - margin - searchHeight,
            width: contentView.bounds.width - margin * 2,
            height: searchHeight
        )
        searchField.autoresizingMask = [.width, .minYMargin]
        searchField.placeholderString = "Search History"
        searchField.delegate = self
        contentView.addSubview(searchField)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelected))
        deleteButton.frame = NSRect(x: margin, y: margin, width: 80, height: buttonRowHeight)
        deleteButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(deleteButton)

        let clearAllButton = NSButton(title: "Clear All History…", target: self, action: #selector(clearAll))
        clearAllButton.frame = NSRect(x: contentView.bounds.width - margin - 170, y: margin, width: 170, height: buttonRowHeight)
        clearAllButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(clearAllButton)

        let scrollY = margin + buttonRowHeight + 8
        let scrollView = NSScrollView(frame: NSRect(
            x: margin,
            y: scrollY,
            width: contentView.bounds.width - margin * 2,
            height: contentView.bounds.height - scrollY - margin - searchHeight - 8
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let titleColumn = NSTableColumn(identifier: .init("title"))
        titleColumn.title = "Title"
        titleColumn.width = 260
        let urlColumn = NSTableColumn(identifier: .init("url"))
        urlColumn.title = "URL"
        urlColumn.width = 220
        let dateColumn = NSTableColumn(identifier: .init("date"))
        dateColumn.title = "Last Visited"
        dateColumn.width = 140

        tableView.addTableColumn(titleColumn)
        tableView.addTableColumn(urlColumn)
        tableView.addTableColumn(dateColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(openSelected)
        tableView.target = self
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
    }

    private func reload(matching query: String? = nil) {
        entries = (try? ProfileDataStoreManager.shared.stores(for: profile).history.entries(matching: query)) ?? []
        tableView.reloadData()
    }

    func controlTextDidChange(_ notification: Notification) {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        reload(matching: text.isEmpty ? nil : text)
    }

    @objc private func deleteSelected() {
        let index = tableView.selectedRow
        guard entries.indices.contains(index) else { return }
        try? ProfileDataStoreManager.shared.stores(for: profile).history.deleteItem(url: entries[index].url)
        reload(matching: currentQuery())
    }

    @objc private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear All History?"
        alert.informativeText = "This removes every history entry for the \"\(profile.name)\" profile. This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? ProfileDataStoreManager.shared.stores(for: profile).history.deleteAll()
        reload()
    }

    @objc private func openSelected() {
        let index = tableView.selectedRow
        guard entries.indices.contains(index) else { return }
        openURL(entries[index].url)
    }

    private func currentQuery() -> String? {
        let text = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Navigates in the profile's frontmost open window (as a new tab) if
    /// one exists, else opens a new window -- same pattern
    /// RoutingCoordinator uses for routed links.
    private func openURL(_ url: String) {
        if let controller = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) {
            controller.addTab(url: url, makeActive: true)
        } else {
            WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let entry = entries[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "title": text = entry.title.isEmpty ? entry.url : entry.title
        case "url": text = entry.url
        case "date": text = Self.dateFormatter.string(from: entry.lastVisitTime)
        default: text = ""
        }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = text
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down -- HistoryWindowManager keeps this controller
        // alive (per profile) across show/hide cycles, same as
        // SettingsWindowController's singleton pattern.
    }
}

/// One HistoryWindowController per profile, reused across `show(for:)` calls
/// rather than spawning a duplicate window every time the shortcut/menu item
/// fires again for the same profile.
final class HistoryWindowManager {
    static let shared = HistoryWindowManager()
    private var controllers: [String: HistoryWindowController] = [:]

    private init() {}

    func show(for profile: Profile) {
        let controller = controllers[profile.id] ?? {
            let created = HistoryWindowController(profile: profile)
            controllers[profile.id] = created
            return created
        }()
        controller.show()
    }
}
