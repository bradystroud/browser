import AppKit

/// "Show Reading List" -- the per-profile list of saved articles
/// (browser-56p), in the same shape as the History and Downloads windows so
/// all three behave identically.
///
/// The one thing here that is not in those windows is the "Unread Only"
/// filter, which is the whole point of a reading list: it is a queue to be
/// worked through, not an archive to be searched.
final class ReadingListWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let profile: Profile
    private let unreadOnlyCheckbox = NSButton()
    private let tableView = NSTableView()
    private let markButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var items: [ReadingListItem] = []
    private var changeObserver: NSObjectProtocol?

    /// Kept alive for the window's lifetime -- see WindowFrameMemory.
    private var frameMemory: WindowFrameMemory?

    init(profile: Profile) {
        self.profile = profile
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Reading List — \(profile.name)"
        window.center()
        super.init(window: window)
        frameMemory = WindowFrameMemory(window: window, name: "reading-list-\(profile.id)")
        window.delegate = self
        setUpViews()
        // The list changes from outside this window all the time -- ⇧⌘D in
        // a browser window, and a capture landing seconds after that -- so
        // it refreshes on the store's own notification rather than only
        // when reopened. Scoped to this profile's own store, so a second
        // profile's reading list window does not redraw this one.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .readingListDidChange,
            object: ReadingListCoordinator.shared.store(for: profile),
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        reload()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
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
        let filterHeight: CGFloat = 24

        unreadOnlyCheckbox.frame = NSRect(
            x: margin,
            y: contentView.bounds.height - margin - filterHeight,
            width: 160,
            height: filterHeight
        )
        unreadOnlyCheckbox.autoresizingMask = [.maxXMargin, .minYMargin]
        unreadOnlyCheckbox.setButtonType(.switch)
        unreadOnlyCheckbox.title = "Unread Only"
        unreadOnlyCheckbox.target = self
        unreadOnlyCheckbox.action = #selector(filterChanged)
        contentView.addSubview(unreadOnlyCheckbox)

        statusLabel.frame = NSRect(
            x: contentView.bounds.width - margin - 300,
            y: contentView.bounds.height - margin - filterHeight,
            width: 300,
            height: filterHeight
        )
        statusLabel.autoresizingMask = [.minXMargin, .minYMargin]
        statusLabel.alignment = .right
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        markButton.frame = NSRect(x: margin, y: margin, width: 130, height: buttonRowHeight)
        markButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        markButton.title = "Mark as Read"
        markButton.bezelStyle = .rounded
        markButton.target = self
        markButton.action = #selector(toggleReadState)
        contentView.addSubview(markButton)

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeSelected))
        removeButton.frame = NSRect(x: margin + 138, y: margin, width: 90, height: buttonRowHeight)
        removeButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(removeButton)

        let removeReadButton = NSButton(title: "Remove Read Items", target: self, action: #selector(removeRead))
        removeReadButton.frame = NSRect(
            x: contentView.bounds.width - margin - 170, y: margin, width: 170, height: buttonRowHeight
        )
        removeReadButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(removeReadButton)

        let scrollY = margin + buttonRowHeight + 8
        let scrollView = NSScrollView(frame: NSRect(
            x: margin,
            y: scrollY,
            width: contentView.bounds.width - margin * 2,
            height: contentView.bounds.height - scrollY - margin - filterHeight - 8
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let titleColumn = NSTableColumn(identifier: .init("title"))
        titleColumn.title = "Title"
        titleColumn.width = 280
        let siteColumn = NSTableColumn(identifier: .init("site"))
        siteColumn.title = "Site"
        siteColumn.width = 130
        let savedColumn = NSTableColumn(identifier: .init("saved"))
        savedColumn.title = "Saved"
        savedColumn.width = 120
        let offlineColumn = NSTableColumn(identifier: .init("offline"))
        offlineColumn.title = "Offline"
        offlineColumn.width = 60

        for column in [titleColumn, siteColumn, savedColumn, offlineColumn] {
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.doubleAction = #selector(openSelected)
        tableView.target = self
        ListAppearance.apply(to: tableView, in: scrollView)
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
    }

    private func reload() {
        let store = ReadingListCoordinator.shared.store(for: profile)
        items = (try? store.items(unreadOnly: unreadOnlyCheckbox.state == .on)) ?? []
        tableView.reloadData()
        updateStatus()
        updateMarkButton()
    }

    private func updateStatus() {
        let unread = (try? ReadingListCoordinator.shared.store(for: profile).unreadCount()) ?? 0
        // The count of items still missing an offline copy is worth saying
        // out loud: it is the difference between a list that can be read on
        // a plane and one that cannot.
        let withoutArticle = items.filter { !$0.hasArticle }.count
        var parts = ["\(unread) unread"]
        if withoutArticle > 0 {
            parts.append("\(withoutArticle) not saved for offline")
        }
        statusLabel.stringValue = parts.joined(separator: " \u{00B7} ")
    }

    private func updateMarkButton() {
        let selected = selectedItem()
        markButton.isEnabled = selected != nil
        markButton.title = (selected?.isRead ?? false) ? "Mark as Unread" : "Mark as Read"
    }

    private func selectedItem() -> ReadingListItem? {
        let index = tableView.selectedRow
        return items.indices.contains(index) ? items[index] : nil
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        reload()
    }

    @objc private func toggleReadState() {
        guard let item = selectedItem() else { return }
        try? ReadingListCoordinator.shared.store(for: profile).markRead(id: item.id, !item.isRead)
    }

    @objc private func removeSelected() {
        guard let item = selectedItem() else { return }
        try? ReadingListCoordinator.shared.store(for: profile).remove(id: item.id)
    }

    @objc private func removeRead() {
        let store = ReadingListCoordinator.shared.store(for: profile)
        let readCount = ((try? store.items().count) ?? 0) - ((try? store.unreadCount()) ?? 0)
        guard readCount > 0 else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = readCount == 1 ? "Remove 1 read item?" : "Remove \(readCount) read items?"
        alert.informativeText = "Their offline copies are deleted too. This cannot be undone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? store.removeRead()
    }

    @objc private func openSelected() {
        guard let item = selectedItem() else { return }
        let url = ReadingListCoordinator.shared.navigationURL(for: item, profile: profile)
        // Same "frontmost window of this profile, else a new one" rule the
        // History window uses, so a saved article opens exactly where any
        // other link would.
        if let controller = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) {
            _ = controller.addTab(url: url, makeActive: true)
        } else {
            WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateMarkButton()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "title": text = item.title.isEmpty ? item.url : item.title
        case "site": text = Self.host(of: item.url)
        case "saved": text = Self.dateFormatter.string(from: item.addedAt)
        case "offline": text = item.hasArticle ? "\u{2713}" : "\u{2014}"
        default: text = ""
        }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = text
        cell.lineBreakMode = .byTruncatingTail
        // Unread is the state that matters at a glance, so it is the one
        // that gets the weight -- read items recede rather than disappear.
        cell.font = item.isRead ? .systemFont(ofSize: 13) : .boldSystemFont(ofSize: 13)
        cell.textColor = item.isRead ? .secondaryLabelColor : .labelColor
        return cell
    }

    private static func host(of url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down -- ReadingListWindowManager keeps this
        // controller alive (per profile) across show/hide cycles, same as
        // HistoryWindowManager.
    }
}

/// One ReadingListWindowController per profile, reused across `show(for:)`
/// calls rather than spawning a duplicate window every time the menu item
/// fires again -- the same shape as HistoryWindowManager.
final class ReadingListWindowManager {
    static let shared = ReadingListWindowManager()
    private var controllers: [String: ReadingListWindowController] = [:]

    private init() {}

    func show(for profile: Profile) {
        let controller = controllers[profile.id] ?? {
            let created = ReadingListWindowController(profile: profile)
            controllers[profile.id] = created
            return created
        }()
        controller.show()
    }
}
