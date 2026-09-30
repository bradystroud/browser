import AppKit

/// The "Profiles" pane of the Settings window (see SettingsWindowController).
/// Lists every profile (color swatch + name), with add/remove under the list
/// and Edit… beside them. "Edit…" reuses NewProfilePrompt's create dialog in
/// edit mode (rename + recolor via the same palette picker). The table
/// supports normal macOS multiple selection (Shift-click for a range,
/// Command-click to toggle). Removing confirms the whole selection first
/// (warning that the profiles' browsing data is removed), refuses to delete
/// every remaining profile, closes any of those profiles' open windows, then
/// bulk-deletes both their persisted entries and on-disk cache directories.
final class ProfilesPaneController: NSObject, NSTableViewDataSource, NSTableViewDelegate, SettingsPaneController {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 400))

    private let tableView = NSTableView()
    private let listButtons = SettingsListButtons(target: nil, action: nil)
    private let editButton = NSButton(title: "Edit…", target: nil, action: nil)
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

    /// The list fills the pane, with its add/remove control flush under it
    /// and Edit… at its right.
    private func setUpViews() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true

        let colorColumn = NSTableColumn(identifier: .init("color"))
        colorColumn.title = ""
        colorColumn.width = 28
        colorColumn.minWidth = 28
        colorColumn.maxWidth = 28
        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Name"
        nameColumn.width = 560

        tableView.addTableColumn(colorColumn)
        tableView.addTableColumn(nameColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.doubleAction = #selector(editSelectedProfile)
        tableView.target = self
        ListAppearance.apply(to: tableView, in: scrollView)
        scrollView.documentView = tableView

        listButtons.target = self
        listButtons.action = #selector(listButtonClicked)
        listButtons.setToolTip("New Profile…", forSegment: SettingsListButtons.addSegment)

        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        editButton.target = self
        editButton.action = #selector(editSelectedProfile)

        for subview in [scrollView, listButtons, editButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        let margin = SettingsForm.margin
        let fillBottom = listButtons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -margin)
        fillBottom.priority = .init(999)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: margin),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: margin),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -margin),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
            listButtons.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            listButtons.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            editButton.centerYAnchor.constraint(equalTo: listButtons.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            fillBottom,
        ])

        tableView.nextKeyView = listButtons
        listButtons.nextKeyView = editButton
        editButton.nextKeyView = tableView
    }

    @objc private func listButtonClicked() {
        switch listButtons.selectedSegment {
        case SettingsListButtons.addSegment: addProfile()
        case SettingsListButtons.removeSegment: deleteSelectedProfiles()
        default: break
        }
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
        let message = count == 1
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
        guard NSAlert.confirmDestructive(
            message: message,
            informativeText: "\(selectedNames)This permanently deletes \(dataOwner) browsing data (cookies, history, cache)\(windowClause). This can't be undone.",
            confirmTitle: count == 1 ? "Delete" : "Delete Profiles"
        ) else { return }

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
        listButtons.canRemove = selectedCount > 0
        listButtons.setToolTip(
            selectedCount > 1 ? "Delete \(selectedCount) Profiles" : "Delete Profile",
            forSegment: SettingsListButtons.removeSegment
        )
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
            return ListAppearance.textCell(in: tableView, identifier: "nameCell", text: profile.name)
        default:
            return nil
        }
    }
}
