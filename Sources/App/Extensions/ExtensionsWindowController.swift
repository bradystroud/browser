import AppKit

/// Window > Extensions… -- one profile's extensions: add one from a Chrome
/// Web Store link, load an unpacked one from a folder (developer mode),
/// turn each on or off, pin it to the toolbar, reload, open its options,
/// remove it, and check the store for updates now rather than waiting for
/// the daily check.
///
/// A window of its own, like Bookmarks and Downloads; Settings > Extensions
/// opens it rather than duplicating it.
final class ExtensionsWindowController: NSWindowController, ProfileWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let profile: Profile
    private let tableView = NSTableView()
    private let storeField = NSTextField()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let optionsButton = NSButton()
    private let reloadButton = NSButton()
    private let removeButton = NSButton()
    private var items: [EngineExtensionSummary] = []
    private var observers: [NSObjectProtocol] = []
    private var frameMemory: WindowFrameMemory?

    private var manager: EngineExtensionManager? { ExtensionsCoordinator.shared.manager }

    init(profile: Profile) {
        self.profile = profile
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Extensions — \(profile.name)"
        window.minSize = NSSize(width: 520, height: 360)
        window.center()
        super.init(window: window)
        frameMemory = WindowFrameMemory(window: window, name: "extensions-\(profile.id)")
        window.delegate = self
        setUpViews()
        observers.append(NotificationCenter.default.addObserver(
            forName: .browserExtensionsDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? String) == self.profile.id else { return }
            self.reload()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .browserExtensionsNotice, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? String) == self.profile.id,
                  let message = notification.userInfo?["message"] as? String else { return }
            self.statusLabel.stringValue = message
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func show() {
        ExtensionsCoordinator.shared.activate()
        manager?.loadExtensions(profileId: profile.id)
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Views

    private func setUpViews() {
        guard let content = window?.contentView else { return }
        let margin: CGFloat = 14
        let rowHeight: CGFloat = 28
        let width = content.bounds.width
        let height = content.bounds.height

        guard manager != nil else {
            let label = NSTextField(wrappingLabelWithString:
                "Extensions need the WebKit engine on macOS 15.4 or later. Choose the engine in Settings › General.")
            label.frame = NSRect(x: margin, y: height / 2 - 30, width: width - margin * 2, height: 60)
            label.alignment = .center
            label.autoresizingMask = [.width, .minYMargin, .maxYMargin]
            content.addSubview(label)
            return
        }

        // Top: add from the store, or from a folder.
        let unpacked = NSButton(title: "Load Unpacked…", target: self, action: #selector(loadUnpacked))
        unpacked.frame = NSRect(x: width - margin - 130, y: height - margin - rowHeight, width: 130, height: rowHeight)
        unpacked.autoresizingMask = [.minXMargin, .minYMargin]
        content.addSubview(unpacked)

        let add = NSButton(title: "Add", target: self, action: #selector(addFromStore))
        add.frame = NSRect(x: unpacked.frame.minX - 8 - 70, y: unpacked.frame.minY, width: 70, height: rowHeight)
        add.autoresizingMask = [.minXMargin, .minYMargin]
        add.keyEquivalent = "\r"
        content.addSubview(add)

        storeField.placeholderString = "Chrome Web Store link or extension id"
        storeField.frame = NSRect(x: margin, y: unpacked.frame.minY + 3, width: add.frame.minX - 8 - margin, height: 22)
        storeField.autoresizingMask = [.width, .minYMargin]
        storeField.target = self
        storeField.action = #selector(addFromStore)
        content.addSubview(storeField)

        // Bottom: actions on the selected extension, and the store check.
        for (button, title, action, x, buttonWidth) in [
            (optionsButton, "Options", #selector(openOptions), margin, CGFloat(90)),
            (reloadButton, "Reload", #selector(reloadSelected), margin + 96, 90),
            (removeButton, "Remove…", #selector(removeSelected), margin + 192, 96),
        ] {
            button.title = title
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.frame = NSRect(x: x, y: margin, width: buttonWidth, height: rowHeight)
            button.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview(button)
        }

        let updates = NSButton(title: "Check for Updates", target: self, action: #selector(checkForUpdates))
        updates.frame = NSRect(x: width - margin - 150, y: margin, width: 150, height: rowHeight)
        updates.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(updates)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: margin, y: margin + rowHeight + 6, width: width - margin * 2, height: 16)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(statusLabel)

        detailLabel.textColor = .secondaryLabelColor
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.isSelectable = true
        let detailY = statusLabel.frame.maxY + 6
        detailLabel.frame = NSRect(x: margin, y: detailY, width: width - margin * 2, height: 70)
        detailLabel.autoresizingMask = [.width, .maxYMargin]
        content.addSubview(detailLabel)

        // Middle: the list.
        let listY = detailLabel.frame.maxY + 8
        let scrollView = NSScrollView(frame: NSRect(
            x: margin, y: listY, width: width - margin * 2, height: storeField.frame.minY - 12 - listY))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        for (id, title, columnWidth) in [("name", "Extension", 420.0), ("enabled", "On", 44.0), ("pinned", "Pinned", 56.0)] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = columnWidth
            if id != "name" { column.resizingMask = [] }
            tableView.addTableColumn(column)
        }
        tableView.dataSource = self
        tableView.delegate = self
        ListAppearance.apply(to: tableView, in: scrollView, rowHeight: 36)
        scrollView.documentView = tableView
        content.addSubview(scrollView)
        updateSelectionDependentViews()
    }

    private func reload() {
        let selectedId = selected?.id
        items = manager?.extensions(profileId: profile.id) ?? []
        tableView.reloadData()
        if let selectedId, let row = items.firstIndex(where: { $0.id == selectedId }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateSelectionDependentViews()
    }

    private var selected: EngineExtensionSummary? {
        let row = tableView.selectedRow
        return items.indices.contains(row) ? items[row] : nil
    }

    private func updateSelectionDependentViews() {
        guard let item = selected else {
            optionsButton.isEnabled = false
            reloadButton.isEnabled = false
            removeButton.isEnabled = false
            detailLabel.stringValue = items.isEmpty
                ? "No extensions yet. Paste a Chrome Web Store link above, or load an unpacked extension's folder."
                : ""
            return
        }
        optionsButton.isEnabled = item.hasOptionsPage && item.isLoaded
        reloadButton.isEnabled = true
        removeButton.isEnabled = true
        var lines = ["ID: \(item.id)"]
        switch item.source {
        case .webStore: lines.append("From the Chrome Web Store")
        case .unpacked(let path): lines.append("Unpacked from \(path)")
        }
        if !item.description.isEmpty { lines.append(item.description) }
        if let error = item.errors.last { lines.append("Error: \(error)") }
        detailLabel.stringValue = lines.joined(separator: "\n")
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        switch column {
        case "enabled", "pinned":
            let checkbox = NSButton(checkboxWithTitle: "", target: self,
                                    action: column == "enabled" ? #selector(toggleEnabled(_:)) : #selector(togglePinned(_:)))
            checkbox.tag = row
            checkbox.state = (column == "enabled" ? item.isEnabled : item.isPinned) ? .on : .off
            if column == "pinned" { checkbox.isEnabled = item.isEnabled }
            return checkbox
        default:
            let cell = NSTableCellView()
            let image = NSImageView(frame: NSRect(x: 2, y: 6, width: 24, height: 24))
            image.image = item.icon ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            var subtitle = "Version \(item.version)"
            if case .unpacked = item.source { subtitle += " · Unpacked" }
            if item.isEnabled, !item.isLoaded { subtitle += " · Couldn't start" }
            if !item.isEnabled { subtitle += " · Off" }
            let text = NSTextField(labelWithString: "")
            text.attributedStringValue = {
                let value = NSMutableAttributedString(string: item.name, attributes: [.font: NSFont.systemFont(ofSize: 13)])
                value.append(NSAttributedString(string: "\n" + subtitle, attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                return value
            }()
            text.frame = NSRect(x: 32, y: 2, width: 380, height: 32)
            text.autoresizingMask = [.width]
            text.lineBreakMode = .byTruncatingTail
            cell.addSubview(text)
            cell.textField = text
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateSelectionDependentViews()
    }

    // MARK: - Actions

    private func run(_ what: String, _ operation: @escaping @MainActor () async throws -> Void) {
        statusLabel.stringValue = what
        Task { @MainActor [weak self] in
            do {
                try await operation()
                if self?.statusLabel.stringValue == what { self?.statusLabel.stringValue = "" }
            } catch {
                let text = (error as? LocalizedError).map { $0.errorDescription } ?? error.localizedDescription
                self?.statusLabel.stringValue = text ?? ""
            }
            self?.reload()
        }
    }

    @objc private func addFromStore() {
        let link = storeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty, let manager else { return }
        let profileId = profile.id
        run("Downloading from the Chrome Web Store…") { [weak self] in
            try await manager.installFromWebStore(link, profileId: profileId)
            self?.storeField.stringValue = ""
        }
    }

    @objc private func loadUnpacked() {
        guard let window, let manager else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Load"
        panel.message = "Choose the folder that holds the extension's manifest.json."
        let profileId = profile.id
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.run("Loading…") {
                try await manager.loadUnpacked(folder: folder, profileId: profileId)
            }
        }
    }

    @objc private func reloadSelected() {
        guard let item = selected, let manager else { return }
        let profileId = profile.id
        run("Reloading \(item.name)…") {
            try await manager.reload(extensionId: item.id, profileId: profileId)
        }
    }

    @objc private func openOptions() {
        guard let item = selected else { return }
        manager?.openOptionsPage(extensionId: item.id, profileId: profile.id)
    }

    @objc private func removeSelected() {
        guard let item = selected, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove “\(item.name)”?"
        alert.informativeText = "Its settings and data in this profile go with it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        let profileId = profile.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.manager?.remove(extensionId: item.id, profileId: profileId)
        }
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        manager?.setEnabled(sender.state == .on, extensionId: items[sender.tag].id, profileId: profile.id)
    }

    @objc private func togglePinned(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        manager?.setPinned(sender.state == .on, extensionId: items[sender.tag].id, profileId: profile.id)
    }

    @objc private func checkForUpdates() {
        guard let manager else { return }
        let profileId = profile.id
        statusLabel.stringValue = "Checking the Chrome Web Store…"
        Task { @MainActor [weak self] in
            let updated = await manager.checkForUpdates(profileId: profileId, force: true)
            self?.statusLabel.stringValue = updated == 0 ? "Everything is up to date." : "Updated \(updated) extension\(updated == 1 ? "" : "s")."
            self?.reload()
        }
    }
}
