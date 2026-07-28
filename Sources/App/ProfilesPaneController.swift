import AppKit

/// The "Profiles" pane of the Settings window (see SettingsWindowController,
/// which hosts this alongside RoutingRulesPaneController in an NSTabView).
/// Lists every profile (color swatch + name), with New/Edit/Delete buttons.
/// "Edit…" reuses NewProfilePrompt's create dialog in edit mode (rename +
/// recolor via the same palette picker). The table supports normal macOS
/// multiple selection (Shift-click for a range, Command-click to toggle).
/// "Delete" confirms the whole selection first (warning that the profiles'
/// browsing data is removed), refuses to delete every remaining profile,
/// closes any of those profiles' open windows, then bulk-deletes both their
/// persisted entries and on-disk cache directories.
final class ProfilesPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 536, height: 400))

    private let tableView = NSTableView()
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var selectedProfileIDs: Set<String> = []
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
        let profiles = ProfileManager.shared.profiles
        let selectedIndexes = IndexSet(profiles.indices.filter { selectedProfileIDs.contains(profiles[$0].id) })
        tableView.selectRowIndexes(selectedIndexes, byExtendingSelection: false)
        selectedProfileIDs = Set(selectedIndexes.map { profiles[$0].id })
        updateActionButtons()
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

        editButton.target = self
        editButton.action = #selector(editSelectedProfile)
        editButton.frame = NSRect(x: margin + 120, y: margin, width: 70, height: buttonRowHeight)
        editButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        view.addSubview(editButton)

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedProfiles)
        deleteButton.frame = NSRect(x: margin + 194, y: margin, width: 150, height: buttonRowHeight)
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
        tableView.allowsMultipleSelection = true
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
        guard tableView.selectedRowIndexes.count == 1, let index = tableView.selectedRowIndexes.first else { return }
        guard ProfileManager.shared.profiles.indices.contains(index) else { return }
        _ = NewProfilePrompt.run(existingProfile: ProfileManager.shared.profiles[index])
    }

    @objc private func deleteSelectedProfiles() {
        let profiles = ProfileManager.shared.profiles
        let selectedProfiles = tableView.selectedRowIndexes.compactMap { index in
            profiles.indices.contains(index) ? profiles[index] : nil
        }
        guard !selectedProfiles.isEmpty else { return }

        guard selectedProfiles.count < profiles.count else {
            let alert = NSAlert()
            alert.messageText = profiles.count == 1
                ? "Can't delete the last profile"
                : "Can't delete every profile"
            alert.informativeText = "Browser always needs at least one profile. Deselect one profile and try again."
            alert.runModal()
            return
        }

        let selectedIDs = Set(selectedProfiles.map(\.id))
        let openWindowCount = WindowManager.shared.windowControllers.filter { selectedIDs.contains($0.profile.id) }.count
        let count = selectedProfiles.count
        let confirm = NSAlert()
        confirm.messageText = count == 1
            ? "Delete profile \"\(selectedProfiles[0].name)\"?"
            : "Delete \(count) profiles?"
        let dataOwner = count == 1 ? "this profile's" : "these profiles'"
        let windowOwner = count == 1 ? "its" : "their"
        let windowClause = openWindowCount > 0
            ? " and closes \(windowOwner) \(openWindowCount) open window\(openWindowCount == 1 ? "" : "s")"
            : ""
        let selectedNames = count > 1
            ? selectedProfiles.map { "\"\($0.name)\"" }.joined(separator: ", ") + "\n\n"
            : ""
        confirm.informativeText = "\(selectedNames)This permanently deletes \(dataOwner) browsing data (cookies, history, cache)\(windowClause). This can't be undone."
        confirm.addButton(withTitle: count == 1 ? "Delete" : "Delete Profiles")
        confirm.addButton(withTitle: "Cancel")
        confirm.buttons.first?.hasDestructiveAction = true
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        for profile in selectedProfiles {
            WindowManager.shared.closeAllWindows(forProfileId: profile.id)
        }
        ProfileManager.shared.deleteProfiles(ids: selectedIDs)
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        ProfileManager.shared.profiles.count
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let profiles = ProfileManager.shared.profiles
        selectedProfileIDs = Set(tableView.selectedRowIndexes.compactMap { index in
            profiles.indices.contains(index) ? profiles[index].id : nil
        })
        updateActionButtons()
    }

    private func updateActionButtons() {
        let selectedCount = tableView.selectedRowIndexes.count
        editButton.isEnabled = selectedCount == 1
        deleteButton.isEnabled = selectedCount > 0
        deleteButton.title = selectedCount > 1 ? "Delete \(selectedCount) Profiles" : "Delete"
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
