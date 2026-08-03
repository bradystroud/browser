import AppKit

private final class AddBookmarkPromptViewController: NSViewController {
    private static let contentSize = NSSize(width: 320, height: 132)

    private let onAdd: (_ name: String, _ folderId: Int64?) -> Void
    private let onCancel: () -> Void
    /// Parallel to folderPopup's items, in the same order -- NSMenuItem
    /// could carry this as representedObject instead, but an Int64? doesn't
    /// bridge to AnyObject without boxing, and a parallel array is simpler
    /// than introducing an NSNumber/NSNull wrapper just for this.
    private let folderIds: [Int64?]

    private var nameField: NSTextField!
    private var folderPopup: NSPopUpButton!

    init(
        pageTitle: String, folderOptions: [(title: String, id: Int64?)], initialSelectionIndex: Int,
        onAdd: @escaping (_ name: String, _ folderId: Int64?) -> Void, onCancel: @escaping () -> Void
    ) {
        self.onAdd = onAdd
        self.onCancel = onCancel
        self.folderIds = folderOptions.map(\.id)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = Self.contentSize
        self.pageTitle = pageTitle
        self.folderTitles = folderOptions.map(\.title)
        self.initialSelectionIndex = initialSelectionIndex
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var pageTitle = ""
    private var folderTitles: [String] = []
    private var initialSelectionIndex = 0

    override func loadView() {
        let size = Self.contentSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let margin: CGFloat = 14
        let labelWidth: CGFloat = 50
        let fieldX = margin + labelWidth
        let fieldWidth = size.width - fieldX - margin

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.alignment = .right
        nameLabel.frame = NSRect(x: margin, y: 96, width: labelWidth - 6, height: 20)
        container.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: fieldX, y: 94, width: fieldWidth, height: 24))
        nameField.stringValue = pageTitle
        nameField.placeholderString = "Bookmark name"
        self.nameField = nameField
        container.addSubview(nameField)

        let folderLabel = NSTextField(labelWithString: "Folder:")
        folderLabel.alignment = .right
        folderLabel.frame = NSRect(x: margin, y: 64, width: labelWidth - 6, height: 20)
        container.addSubview(folderLabel)

        let folderPopup = NSPopUpButton(frame: NSRect(x: fieldX, y: 60, width: fieldWidth, height: 24), pullsDown: false)
        folderPopup.addItems(withTitles: folderTitles)
        if folderTitles.indices.contains(initialSelectionIndex) {
            folderPopup.selectItem(at: initialSelectionIndex)
        }
        self.folderPopup = folderPopup
        container.addSubview(folderPopup)

        let buttonHeight: CGFloat = 24
        let addButton = NSButton(title: "Add", target: self, action: #selector(addTapped))
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        addButton.frame = NSRect(x: size.width - margin - 70, y: margin, width: 70, height: buttonHeight)
        container.addSubview(addButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        cancelButton.frame = NSRect(x: size.width - margin - 70 - 8 - 70, y: margin, width: 70, height: buttonHeight)
        container.addSubview(cancelButton)

        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
        // Select the prefilled text (matches Safari's own Add Bookmark
        // sheet) so typing a replacement name doesn't need a manual
        // select-all first.
        nameField.currentEditor()?.selectAll(nil)
    }

    @objc private func addTapped() {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? pageTitle : trimmed
        let selected = folderPopup.indexOfSelectedItem
        let folderId = folderIds.indices.contains(selected) ? folderIds[selected] : nil
        onAdd(name, folderId)
    }

    @objc private func cancelTapped() { onCancel() }
}

/// "Add Bookmark" popover -- editable name (prefilled from the page's
/// title) + a folder picker defaulting to Favorites, Add/Cancel. Same
/// NSPopover-anchored-under-the-omnibox pattern as
/// SavePasswordPromptController/SaveAutofillPromptController/
/// PermissionPromptController, reused rather than duplicated: this is the
/// only path that can actually land a page in the start page's Favorites
/// grid (browser-5kq.7) -- ⌘D used to silently file a plain top-level
/// bookmark with no way to choose Favorites at all (see the old
/// FavoritesFolder.swift doc comment, now stale).
///
/// One instance per window (owned by BrowserWindowController, same as
/// permissionPrompt), at most one prompt showing at a time.
final class AddBookmarkPromptController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var isPending = false

    override init() {
        super.init()
        popover.behavior = .semitransient
        popover.delegate = self
    }

    var isShowing: Bool { popover.isShown }

    /// `bookmarks` is read synchronously here (BookmarkStore's SQLite calls
    /// are all synchronous, same as every other call site in this file) to
    /// build the folder picker's options before the popover ever appears --
    /// Favorites always comes first (creating it, still empty, if this
    /// profile has never had one -- same lazy-create FavoritesFolder.id
    /// already does for the start page itself), followed by every other
    /// top-level folder in their existing order, followed by "Bookmarks"
    /// (the top level itself, id nil) for parity with ⌘D's old behavior.
    func show(pageTitle: String, bookmarks: BookmarkStore, anchorView: NSView, onAdd: @escaping (_ name: String, _ folderId: Int64?) -> Void) {
        dismiss()
        isPending = true

        let favoritesId = FavoritesFolder.id(in: bookmarks)
        let topLevel = (try? bookmarks.children(of: nil)) ?? []
        var options: [(title: String, id: Int64?)] = []
        if let favoritesId {
            options.append((FavoritesFolder.title, favoritesId))
        }
        for item in topLevel where item.kind == .folder && item.id != favoritesId {
            options.append((item.title, item.id))
        }
        options.append(("Bookmarks", nil))

        let content = AddBookmarkPromptViewController(
            pageTitle: pageTitle,
            folderOptions: options,
            initialSelectionIndex: 0,
            onAdd: { [weak self] name, folderId in self?.complete { onAdd(name, folderId) } },
            onCancel: { [weak self] in self?.complete {} }
        )
        popover.contentViewController = content
        popover.contentSize = content.preferredContentSize
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    /// Tears down the popover without adding anything -- used when something
    /// else needs the prompt gone (a new one about to show, the tab
    /// switching away) rather than the user actually answering it.
    func dismiss() {
        isPending = false
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func complete(_ action: () -> Void) {
        guard isPending else { return }
        isPending = false
        popover.performClose(nil)
        action()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // An outside click / Esc closes the popover without going through
        // complete(_:) -- treat that like Cancel (do nothing).
        isPending = false
    }
}
