import AppKit

/// "Show All Bookmarks…" manager -- a folder tree (NSOutlineView) backed by
/// BookmarkStore, with New Folder / Rename / Delete. There's no drag-and-drop
/// reordering in this window (see docs/ai-tasks/m3-furniture-notes.md for
/// that scope cut); items land at the end of their parent via addFolder/
/// addBookmark's own append-at-end behavior.
final class BookmarksWindowController: NSWindowController, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let profile: Profile
    private let outlineView = NSOutlineView()

    private var store: BookmarkStore {
        ProfileDataStoreManager.shared.stores(for: profile).bookmarks
    }

    /// Kept alive for the window's lifetime -- see WindowFrameMemory.
    private var frameMemory: WindowFrameMemory?

    init(profile: Profile) {
        self.profile = profile
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bookmarks — \(profile.name)"
        window.center()
        super.init(window: window)
        frameMemory = WindowFrameMemory(window: window, name: "bookmarks-\(profile.id)")
        window.delegate = self
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        outlineView.reloadData()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }
        let margin: CGFloat = 12
        let buttonRowHeight: CGFloat = 28

        let newFolderButton = NSButton(title: "New Folder", target: self, action: #selector(newFolder))
        newFolderButton.frame = NSRect(x: margin, y: margin, width: 100, height: buttonRowHeight)
        newFolderButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(newFolderButton)

        let renameButton = NSButton(title: "Rename…", target: self, action: #selector(renameSelected))
        renameButton.frame = NSRect(x: margin + 104, y: margin, width: 90, height: buttonRowHeight)
        renameButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(renameButton)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelected))
        deleteButton.frame = NSRect(x: margin + 198, y: margin, width: 80, height: buttonRowHeight)
        deleteButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(deleteButton)

        let scrollY = margin + buttonRowHeight + 8
        let scrollView = NSScrollView(frame: NSRect(
            x: margin,
            y: scrollY,
            width: contentView.bounds.width - margin * 2,
            height: contentView.bounds.height - scrollY - margin
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true

        let column = NSTableColumn(identifier: .init("title"))
        column.title = "Bookmarks"
        column.width = 380
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.doubleAction = #selector(openOrToggleSelected)
        outlineView.target = self
        ListAppearance.apply(to: outlineView, in: scrollView)
        scrollView.documentView = outlineView
        contentView.addSubview(scrollView)
    }

    // MARK: - Actions

    @objc private func newFolder() {
        guard let name = promptForText(title: "New Folder", placeholder: "Folder name", initialValue: "") else { return }
        let parent = selectedFolderOrNil()
        try? store.addFolder(title: name, parentId: parent?.id)
        outlineView.reloadItem(parent, reloadChildren: true)
        if parent == nil {
            outlineView.reloadData()
        }
    }

    @objc private func renameSelected() {
        guard let item = selectedItem() else { return }
        guard let name = promptForText(title: "Rename", placeholder: "Name", initialValue: item.title) else { return }
        try? store.rename(itemId: item.id, title: name)
        outlineView.reloadData()
    }

    @objc private func deleteSelected() {
        guard let item = selectedItem() else { return }
        try? store.delete(itemId: item.id)
        outlineView.reloadData()
    }

    @objc private func openOrToggleSelected() {
        guard let item = selectedItem() else { return }
        if item.kind == .folder {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
            return
        }
        guard let url = item.url else { return }
        if let controller = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) {
            controller.addTab(url: url, makeActive: true)
        } else {
            WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
        }
    }

    private func promptForText(title: String, placeholder: String, initialValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initialValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func selectedItem() -> BookmarkItem? {
        let row = outlineView.selectedRow
        guard row >= 0 else { return nil }
        return outlineView.item(atRow: row) as? BookmarkItem
    }

    private func selectedFolderOrNil() -> BookmarkItem? {
        guard let item = selectedItem() else { return nil }
        return item.kind == .folder ? item : nil
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        let parentId = (item as? BookmarkItem)?.id
        return (try? store.children(of: parentId))?.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let parentId = (item as? BookmarkItem)?.id
        let children = (try? store.children(of: parentId)) ?? []
        return children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BookmarkItem)?.kind == .folder
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let bookmarkItem = item as? BookmarkItem else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        cell.identifier = identifier
        cell.stringValue = bookmarkItem.kind == .folder ? "\u{1F4C1} \(bookmarkItem.title)" : bookmarkItem.title
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down -- BookmarksWindowManager keeps this
        // controller alive (per profile) across show/hide cycles.
    }
}

final class BookmarksWindowManager {
    static let shared = BookmarksWindowManager()
    private var controllers: [String: BookmarksWindowController] = [:]

    private init() {}

    func show(for profile: Profile) {
        let controller = controllers[profile.id] ?? {
            let created = BookmarksWindowController(profile: profile)
            controllers[profile.id] = created
            return created
        }()
        controller.show()
    }
}
