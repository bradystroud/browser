import AppKit

/// Drag-to-reorder hand-off (browser-rhi.6). A tab button knows nothing about
/// ordering or layout -- it just reports "the user pressed me", and whoever
/// owns the strip's geometry (TabStripView) takes over the rest of the mouse
/// sequence and does all the reflow work.
///
/// Deliberately plain event tracking rather than NSDraggingSession: the
/// reorder is entirely within one strip, and a dragging session would mean
/// giving up direct control of the dragged pill's position (what moves is a
/// drag image, not the real view) for pasteboard machinery this doesn't need.
/// Tearing a tab out into another window would want that machinery -- adding
/// it later means adding a second, drag-session path here, not unpicking this
/// one, since this protocol says nothing about where a drag may end.
protocol TabButtonDragDelegate: AnyObject {
    func tabButton(_ button: TabButtonView, didBeginDragWith event: NSEvent)
}

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
    /// Speaker icon click, or context menu's "Mute Tab"/"Unmute Tab"
    /// (browser-rhi.4) -- same "just report toggle requested" shape as
    /// onPinToggle above; BrowserWindowController owns the actual
    /// Tab.toggleMuted() call.
    var onMuteToggle: (() -> Void)?

    /// Drag-to-reorder (browser-rhi.6) -- set by TabStripView.rebuildButtons.
    weak var dragDelegate: TabButtonDragDelegate?

    /// Which group (if any) this tab currently belongs to -- gates whether
    /// "Remove from Group" appears in the context menu. Set by
    /// TabStripView.rebuildButtons from Tab.groupId; this view never
    /// mutates it directly.
    var groupId: UUID?
    /// Every group in the owning window, for the "Move to Group >" submenu
    /// -- set by TabStripView.rebuildButtons alongside groupId.
    var availableGroups: [(id: UUID, name: String)] = []

    /// The page's `<meta name="theme-color">` value, if any (browser-rhi.5)
    /// -- see draw(_:) for why this only ever visibly tints while isSelected
    /// is also true.
    var themeColorHex: String? {
        didSet {
            guard oldValue != themeColorHex else { return }
            needsDisplay = true
            updateGlassAppearance()
        }
    }

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
            updateGlassAppearance()
        }
    }

    /// Mirrors Tab.isMuted (browser-rhi.4) -- see updateIconState() for
    /// how this and isAudible/isLoading below combine into the icon shown
    /// in the shared favicon slot.
    var isMuted = false {
        didSet {
            guard oldValue != isMuted else { return }
            updateIconState()
        }
    }

    /// Mirrors Tab.isAudible (browser-rhi.4).
    var isAudible = false {
        didSet {
            guard oldValue != isAudible else { return }
            updateIconState()
        }
    }

    /// Mirrors Tab.isLoading (browser-7z5, Brady's ask -- background tabs
    /// currently give no visible sign anything's happening). Shares the
    /// favicon's slot -- see updateIconState() for the full audio > spinner
    /// > favicon precedence when more than one could apply at once.
    var isLoading = false {
        didSet {
            guard oldValue != isLoading else { return }
            updateIconState()
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

    /// Speaker glyph shown in place of the favicon whenever isAudible ||
    /// isMuted (browser-rhi.4), matching Safari's own tab-icon convention --
    /// clicking it toggles mute, same as clicking Safari's tab speaker icon.
    /// Hidden the rest of the time, in which case faviconView or the
    /// spinner below is what shows -- see updateIconState() for the
    /// precedence between all three.
    private let audioButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.imageScaling = .scaleProportionallyDown
        button.isHidden = true
        return button
    }()

    /// Shown in the favicon's slot while isLoading, unless isMuted/isAudible
    /// also applies (browser-7z5, Brady's ask -- this is what makes a
    /// loading *background* tab visible at all, which the old "no feedback
    /// at all" behavior never gave). See updateIconState() for the
    /// audio > spinner > favicon precedence.
    private let loadingSpinner: NSProgressIndicator = {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isHidden = true
        return spinner
    }()

    private var trackingArea: NSTrackingArea?

    /// `NSGlassEffectView` on macOS 26+ -- see GlassBackgroundView's own doc
    /// comment on why this is stored untyped. `nil` pre-26, in which case
    /// draw(_:) falls back to its original bezier-fill rendering unchanged.
    private var glassBackground: NSView?

    /// Real content (favicon/title/audio/close button) lives here, not
    /// directly on `self` (browser-0y1: titles/favicons rendered blurred,
    /// and a selected tab's title disappeared entirely, because this view
    /// used to add them as plain sibling subviews of its own
    /// `NSGlassEffectView` -- that view's own header doc comment only
    /// guarantees correct z-order for its `contentView`, not arbitrary
    /// siblings; see GlassBackgroundView.contentContainer's own doc comment
    /// for the same fix applied there). On macOS 26+ this becomes the
    /// glass's `contentView`; pre-26 it's a plain full-size subview of
    /// `self`, sitting on top of `self`'s own bezier-filled layer exactly
    /// as the un-nested subviews used to.
    private let contentContainer = NSView()

    init(index: Int, title: String) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true

        titleLabel.stringValue = title
        contentContainer.addSubview(faviconView)
        contentContainer.addSubview(loadingSpinner)
        contentContainer.addSubview(titleLabel)

        audioButton.target = self
        audioButton.action = #selector(muteToggleTapped)
        contentContainer.addSubview(audioButton)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        contentContainer.addSubview(closeButton)

        // Real Liquid Glass material for the pill itself (browser-qpy
        // rework), hosting contentContainer as its contentView so the
        // favicon/title/buttons above are guaranteed to render on top of
        // the glass effect, not composited underneath it. draw(_:) skips
        // its bezier fill entirely whenever this exists (see draw(_:));
        // pre-26 this stays nil and draw(_:) is the only rendering path,
        // unchanged from before this rework.
        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.contentView = contentContainer
            addSubview(glass)
            glassBackground = glass
        } else {
            addSubview(contentContainer)
        }

        updateGlassAppearance()
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
        // Full pill shape (browser-qpy): fully rounded ends at any height,
        // not a fixed radius -- matches the compact pinned width too. On
        // macOS 26+ the real glass view masks its own corners; masking
        // this view's own layer too would double up (and clip nothing
        // extra, since the glass view already fills these bounds).
        if #available(macOS 26.0, *), let glass = glassBackground as? NSGlassEffectView {
            glass.cornerRadius = bounds.height / 2
        } else {
            layer?.cornerRadius = bounds.height / 2
        }
        let closeSize: CGFloat = 14
        let faviconSize: CGFloat = 14

        guard !isPinned else {
            // Compact: favicon (or the audio glyph, when relevant) centered,
            // no title, no close button.
            let iconFrame = NSRect(
                x: (bounds.width - faviconSize) / 2,
                y: (bounds.height - faviconSize) / 2,
                width: faviconSize,
                height: faviconSize
            )
            faviconView.frame = iconFrame
            audioButton.frame = iconFrame
            loadingSpinner.frame = iconFrame
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
        let iconFrame = NSRect(
            x: faviconLeading,
            y: (bounds.height - faviconSize) / 2,
            width: faviconSize,
            height: faviconSize
        )
        faviconView.frame = iconFrame
        audioButton.frame = iconFrame
        loadingSpinner.frame = iconFrame
        let titleX = faviconLeading + faviconSize + 6
        // Vertically centered as its own row alongside the favicon above
        // (browser-0y1, Brady's ask) -- a plain NSTextField label renders
        // its text top-aligned within whatever frame it's given, so a
        // frame spanning the full tab height (the old behavior) left the
        // title sitting at the top instead of centered. A fixed label
        // height matching the font's own line height, centered the same
        // way faviconView/audioButton already are, fixes that.
        let titleHeight: CGFloat = 16
        titleLabel.frame = NSRect(
            x: titleX, y: (bounds.height - titleHeight) / 2,
            width: max(0, bounds.width - closeSize - titleX - 8), height: titleHeight
        )
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

    /// Selection happens on mouse *down*, before any drag is known about --
    /// same as Safari, and what makes "a click that never moved still selects
    /// the tab" fall out for free rather than needing a movement threshold to
    /// resolve first (browser-rhi.6). Dragging a background tab therefore also
    /// activates it, which is again Safari's behavior.
    ///
    /// The close and speaker buttons are real NSButtons inside contentContainer
    /// and swallow their own mouse-downs, so neither selection nor a drag ever
    /// starts from clicking one.
    override func mouseDown(with event: NSEvent) {
        onSelect?()
        dragDelegate?.tabButton(self, didBeginDragWith: event)
    }

    /// Right-click/Control-click context menu -- built fresh each time (not
    /// kept as a stored menu) so "Pin Tab"/"Unpin Tab", the group submenu,
    /// and "Remove from Group" all reflect current state. Kept minimal per
    /// scope: Pin/Unpin, Move to Group > (existing groups…, New Group…),
    /// Remove from Group (only if currently grouped), Close Tab, Close
    /// Other Tabs -- no icons (see browser-rhi.1's notes).
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: isPinned ? "Unpin Tab" : "Pin Tab", action: #selector(pinToggleTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: isMuted ? "Unmute Tab" : "Mute Tab", action: #selector(muteToggleTapped), keyEquivalent: "").target = self

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

    /// Picks exactly one of audioButton / loadingSpinner / faviconView to
    /// show in the shared icon slot, precedence audio > spinner > favicon
    /// (browser-7z5, Brady's ask, documented explicitly since it wasn't
    /// obvious which should win when more than one applies at once): a
    /// muted/audible tab keeps showing that state even while also loading
    /// (matching browser-rhi.4's own established "isMuted takes precedence
    /// over isAudible" precedent -- the mute/audio state is something the
    /// user acted on and is more persistent/important than a transient
    /// loading spinner), and a merely-loading tab shows the spinner in
    /// place of its favicon (which would otherwise just look frozen/stale
    /// for however long the load takes, especially for a background tab).
    private func updateIconState() {
        audioButton.isHidden = true
        loadingSpinner.isHidden = true
        loadingSpinner.stopAnimation(nil)
        faviconView.isHidden = false

        if isMuted || isAudible {
            audioButton.image = NSImage(
                systemSymbolName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                accessibilityDescription: isMuted ? "Muted -- click to unmute" : "Playing audio -- click to mute"
            )
            audioButton.isHidden = false
            faviconView.isHidden = true
        } else if isLoading {
            loadingSpinner.isHidden = false
            loadingSpinner.startAnimation(nil)
            faviconView.isHidden = true
        }
    }

    @objc private func muteToggleTapped() {
        onMuteToggle?()
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

    /// Liquid-glass pill (browser-qpy): an inactive tab is translucent --
    /// just a faint label-color wash, letting the vibrant chrome material
    /// behind the strip show through -- while the active tab is a brighter,
    /// more opaque pill so it reads clearly as "the current one" against
    /// its translucent neighbors. Only the *selected* tab's button ever
    /// shows the theme-color tint (browser-rhi.5's brief: "a subtle tint to
    /// the active tab's button" -- singular): an unselected tab ignores its
    /// own stored themeColorHex, matching how the toolbar tint also only
    /// ever reflects whichever tab is currently active (see
    /// BrowserWindowController.refreshToolbar(for:)).
    private static let inactiveWashAlpha: CGFloat = 0.10

    override func draw(_ dirtyRect: NSRect) {
        // macOS 26+: the real glass view (added behind everything in init)
        // is the pill's entire material -- see updateGlassAppearance() for
        // how it reflects isSelected/themeColorHex instead of this fill.
        guard glassBackground == nil else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        if isSelected {
            let base = NSColor.controlBackgroundColor
            (base.tinted(withThemeColorHex: themeColorHex) ?? base).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(Self.inactiveWashAlpha).setFill()
        }
        path.fill()
    }

    /// Mirrors draw(_:)'s selected/unselected look onto the real glass
    /// view's own style/tint properties (macOS 26+ only) -- `.clear` style
    /// with no tint for an inactive, barely-there pill (glass's own
    /// analogue of the bezier path's faint label-color wash); `.regular`
    /// style tinted toward the theme color for the active tab (glass's own
    /// analogue of the opaque-ish controlBackgroundColor fill). No-op
    /// pre-26 (glassBackground is nil, draw(_:) handles it instead).
    private func updateGlassAppearance() {
        guard #available(macOS 26.0, *), let glass = glassBackground as? NSGlassEffectView else { return }
        if isSelected {
            glass.style = .regular
            glass.tintColor = NSColor.controlBackgroundColor.tinted(withThemeColorHex: themeColorHex)
        } else {
            glass.style = .clear
            glass.tintColor = nil
        }
    }
}
