import AppKit

/// One tab's visual representation in the strip: title + a close button that
/// only appears on hover (Safari-style), selected/unselected background.
final class TabButtonView: NSView {
    let index: Int
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    /// Context menu's "Pin Tab"/"Unpin Tab" -- BrowserWindowController
    /// decides which of pinTab(at:)/unpinTab(at:) to call based on the
    /// tab's current state, this button just reports "toggle requested."
    var onPinToggle: (() -> Void)?
    /// Context menu's "Close Other Tabs".
    var onCloseOthers: (() -> Void)?
    /// Context menu's "Move to Group > <existing group>" -- the chosen
    /// group's id.
    var onMoveToGroup: ((UUID) -> Void)?
    /// Context menu's "Move to Group > New Group…".
    var onMoveToNewGroup: (() -> Void)?
    /// Context menu's "Remove from Group" (only shown when groupId != nil).
    var onRemoveFromGroup: (() -> Void)?

    /// Which group (if any) this tab currently belongs to -- gates whether
    /// "Remove from Group" appears in the context menu. Set by
    /// TabStripView.rebuildButtons from Tab.groupId; this view never
    /// mutates it directly.
    var groupId: UUID?
    /// Every group in the owning window, for the "Move to Group >" submenu
    /// -- set by TabStripView.rebuildButtons alongside groupId.
    var availableGroups: [(id: UUID, name: String)] = []

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
        }
    }

    /// Pinned tabs render compact -- favicon-only, fixed narrow width (see
    /// TabStripView.layoutTabs), no close button regardless of hover state.
    var isPinned = false {
        didSet {
            guard oldValue != isPinned else { return }
            titleLabel.isHidden = isPinned
            // Pinning always hides the close button; unpinning restores it
            // only if the mouse happens to already be hovering (mouseEntered
            // won't refire just because isPinned changed under the cursor).
            closeButton.isHidden = isPinned || !isMouseInside
            needsLayout = true
        }
    }

    /// Tracked separately from closeButton.isHidden so a pin toggled while
    /// the mouse is already hovering doesn't leave stale hover state behind
    /// once unpinned again -- mouseExited isn't guaranteed to fire from a
    /// state change that didn't move the mouse.
    private var isMouseInside = false

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        return label
    }()

    /// Generic fallback shown until FaviconLoader resolves a real one (or
    /// permanently, if the site has none or it fails to load) -- see
    /// setFavicon(_:).
    private static let genericFavicon = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")

    private let faviconView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = TabButtonView.genericFavicon
        return imageView
    }()

    private let closeButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        button.imageScaling = .scaleProportionallyDown
        button.isHidden = true
        return button
    }()

    private var trackingArea: NSTrackingArea?

    init(index: Int, title: String) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        titleLabel.stringValue = title
        addSubview(faviconView)
        addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    /// `nil` reverts to the generic globe glyph (e.g. a site with no
    /// favicon, or one FaviconLoader couldn't fetch).
    func setFavicon(_ image: NSImage?) {
        faviconView.image = image ?? Self.genericFavicon
    }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 14
        let faviconSize: CGFloat = 14

        guard !isPinned else {
            // Compact: favicon centered, no title, no close button.
            faviconView.frame = NSRect(
                x: (bounds.width - faviconSize) / 2,
                y: (bounds.height - faviconSize) / 2,
                width: faviconSize,
                height: faviconSize
            )
            closeButton.frame = .zero
            titleLabel.frame = .zero
            return
        }

        let faviconLeading: CGFloat = 8
        closeButton.frame = NSRect(
            x: bounds.width - closeSize - 6,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
        faviconView.frame = NSRect(
            x: faviconLeading,
            y: (bounds.height - faviconSize) / 2,
            width: faviconSize,
            height: faviconSize
        )
        let titleX = faviconLeading + faviconSize + 6
        titleLabel.frame = NSRect(x: titleX, y: 0, width: max(0, bounds.width - closeSize - titleX - 8), height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        guard !isPinned else { return }
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        closeButton.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    /// Right-click/Control-click context menu -- built fresh each time (not
    /// kept as a stored menu) so "Pin Tab"/"Unpin Tab", the group submenu,
    /// and "Remove from Group" all reflect current state. Kept minimal per
    /// scope: Pin/Unpin, Move to Group > (existing groups…, New Group…),
    /// Remove from Group (only if currently grouped), Close Tab, Close
    /// Other Tabs -- no icons, no drag-reorder (see browser-rhi.1's notes).
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: isPinned ? "Unpin Tab" : "Pin Tab", action: #selector(pinToggleTapped), keyEquivalent: "").target = self

        let moveToGroupItem = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for group in availableGroups {
            let item = NSMenuItem(title: group.name, action: #selector(moveToExistingGroupTapped(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = group.id
            submenu.addItem(item)
        }
        if !availableGroups.isEmpty {
            submenu.addItem(.separator())
        }
        submenu.addItem(withTitle: "New Group…", action: #selector(moveToNewGroupTapped), keyEquivalent: "").target = self
        moveToGroupItem.submenu = submenu
        menu.addItem(moveToGroupItem)

        if groupId != nil {
            menu.addItem(withTitle: "Remove from Group", action: #selector(removeFromGroupTapped), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Tab", action: #selector(closeTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Other Tabs", action: #selector(closeOthersTapped), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func closeTapped() {
        onClose?()
    }

    @objc private func pinToggleTapped() {
        onPinToggle?()
    }

    @objc private func closeOthersTapped() {
        onCloseOthers?()
    }

    @objc private func moveToExistingGroupTapped(_ sender: NSMenuItem) {
        guard let groupId = sender.representedObject as? UUID else { return }
        onMoveToGroup?(groupId)
    }

    @objc private func moveToNewGroupTapped() {
        onMoveToNewGroup?()
    }

    @objc private func removeFromGroupTapped() {
        onRemoveFromGroup?()
    }

    /// Brief shake to signal a keypress registered but was intentionally a
    /// no-op -- see BrowserWindowController.closeTab(_:) (⌘W on a pinned
    /// active tab).
    func shake() {
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, -4, 4, -3, 3, -1, 1, 0]
        animation.duration = 0.3
        animation.isAdditive = true
        layer?.add(animation, forKey: "shake")
    }

    override func draw(_ dirtyRect: NSRect) {
        (isSelected ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).setFill()
        dirtyRect.fill()
    }
}
