import AppKit

/// The "Profiles" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside RoutingRulesPaneController in an NSTabView).
/// Lists every profile (color swatch + name), with New/Edit/Delete buttons.
/// "Edit…" reuses NewProfilePrompt's create dialog in edit mode (rename +
/// recolor via the same palette picker). "Delete" confirms first (warning
/// that the profile's browsing data is removed), refuses to delete the last
/// remaining profile, closes any of that profile's open windows, then
/// deletes both the persisted entry and its on-disk cache directory.
final class ProfilesPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let tableView = NSTableView()
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

    func reload() {
        tableView.reloadData()
    }

    // MARK: - View setup

    private func setUpViews() {
        let margin: CGFloat = 12
        let rowGap: CGFloat = 10
        let headerHeight: CGFloat = 22
        let buttonRowHeight: CGFloat = 28

        let headerLabel = NSTextField(labelWithString: "Profiles")
        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.frame = NSRect(
            x: margin,
            y: view.bounds.height - margin - headerHeight,
            width: view.bounds.width - margin * 2,
            height: headerHeight
        )
        headerLabel.autoresizingMask = [.width, .minYMargin]
        view.addSubview(headerLabel)

        let addButton = NSButton(title: "New Profile…", target: self, action: #selector(addProfile))
        addButton.frame = NSRect(x: margin, y: margin, width: 116, height: buttonRowHeight)
        addButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(addButton)

        let editButton = NSButton(title: "Edit…", target: self, action: #selector(editSelectedProfile))
        editButton.frame = NSRect(x: margin + 120, y: margin, width: 70, height: buttonRowHeight)
        editButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(editButton)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelectedProfile))
        deleteButton.frame = NSRect(x: margin + 194, y: margin, width: 70, height: buttonRowHeight)
        deleteButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(deleteButton)

        let scrollViewY = margin + buttonRowHeight + rowGap
        let scrollView = NSScrollView(frame: NSRect(
            x: margin,
            y: scrollViewY,
            width: view.bounds.width - margin * 2,
            height: view.bounds.height - margin - headerHeight - scrollViewY
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let colorColumn = NSTableColumn(identifier: .init("color"))
        colorColumn.title = ""
        colorColumn.width = 28
        colorColumn.minWidth = 28
        colorColumn.maxWidth = 28
        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Name"
        nameColumn.width = 460

        tableView.rowHeight = 24
        tableView.addTableColumn(colorColumn)
        tableView.addTableColumn(nameColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.doubleAction = #selector(editSelectedProfile)
        tableView.target = self
        scrollView.documentView = tableView
        view.addSubview(scrollView)
    }

    // MARK: - Actions

    @objc private func addProfile() {
        _ = NewProfilePrompt.run()
        // No explicit reload() needed: ProfileManager.save() posts
        // .profileManagerDidChange, which this pane observes.
    }

    @objc private func editSelectedProfile() {
        let index = tableView.selectedRow
        guard ProfileManager.shared.profiles.indices.contains(index) else { return }
        _ = NewProfilePrompt.run(existingProfile: ProfileManager.shared.profiles[index])
    }

    @objc private func deleteSelectedProfile() {
        let index = tableView.selectedRow
        guard ProfileManager.shared.profiles.indices.contains(index) else { return }
        let profile = ProfileManager.shared.profiles[index]

        guard ProfileManager.shared.profiles.count > 1 else {
            let alert = NSAlert()
            alert.messageText = "Can't delete the last profile"
            alert.informativeText = "Browser always needs at least one profile."
            alert.runModal()
            return
        }

        let openWindowCount = WindowManager.shared.windowControllers.filter { $0.profile.id == profile.id }.count
        let confirm = NSAlert()
        confirm.messageText = "Delete profile \"\(profile.name)\"?"
        confirm.informativeText = openWindowCount > 0
            ? "This permanently deletes this profile's browsing data (cookies, history, cache) and closes its \(openWindowCount) open window\(openWindowCount == 1 ? "" : "s"). This can't be undone."
            : "This permanently deletes this profile's browsing data (cookies, history, cache). This can't be undone."
        confirm.addButton(withTitle: "Delete")
        confirm.addButton(withTitle: "Cancel")
        confirm.buttons.first?.hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        WindowManager.shared.closeAllWindows(forProfileId: profile.id)
        ProfileManager.shared.deleteProfile(id: profile.id)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        ProfileManager.shared.profiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard ProfileManager.shared.profiles.indices.contains(row) else { return nil }
        let profile = ProfileManager.shared.profiles[row]

        switch tableColumn?.identifier.rawValue {
        case "color":
            // A fresh small container each time (rows are few, no perf
            // concern) -- ProfileDotView draws a circle filling its own
            // bounds, so it's centered in a fixed 10x10 frame within the
            // column/row's wider cell rather than stretched to fill it.
            let container = NSView(frame: NSRect(x: 0, y: 0, width: tableColumn?.width ?? 28, height: tableView.rowHeight))
            let dot = ProfileDotView(colorHex: profile.colorHex)
            dot.frame.origin = NSPoint(
                x: (container.bounds.width - dot.frame.width) / 2,
                y: (container.bounds.height - dot.frame.height) / 2
            )
            container.addSubview(dot)
            return container
        case "name":
            let identifier = NSUserInterfaceItemIdentifier("nameCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
                ?? NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.stringValue = profile.name
            return cell
        default:
            return nil
        }
    }
}
