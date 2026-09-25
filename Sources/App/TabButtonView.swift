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
    /// Both of these are also driven by TabStripView's own event monitor, and
    /// are idempotent for exactly that reason -- see TabStripView's
    /// continueDrag/endDrag and the notes file's "two paths" section.
    func tabButton(_ button: TabButtonView, didDragWith event: NSEvent)
    func tabButton(_ button: TabButtonView, didEndDragWith event: NSEvent)
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
            updateSelectionAppearance()
        }
    }

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
            updateSelectionAppearance()
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

    /// True while this pill is a row in the vertical sidebar rather than a
    /// cell in the horizontal strip (see TabStripOrientation). It changes
    /// three things and nothing else: the title reads from the leading edge
    /// instead of centred (a column of centred titles is unreadable -- the
    /// eye has no common left margin to run down), the corner radius stops
    /// being a full capsule at a width that would make one look like a
    /// lozenge, and an unselected row highlights on hover, which is what a
    /// list of rows is expected to do and a strip of pills is not.
    var isVerticalLayout = false {
        didSet {
            guard oldValue != isVerticalLayout else { return }
            titleLabel.alignment = isVerticalLayout ? .left : .center
            updateSelectionAppearance()
            needsLayout = true
        }
    }

    /// Tracked separately from closeButton.isHidden so a pin toggled while
    /// the mouse is already hovering doesn't leave stale hover state behind
    /// once unpinned again -- mouseExited isn't guaranteed to fire from a
    /// state change that didn't move the mouse. Also drives the sidebar's
    /// hover highlight -- see isVerticalLayout.
    private var isMouseInside = false

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        // Centered in the pill (Brady's ask) -- see layout() for the
        // symmetric insets that make "centered in the label" and "centered
        // in the pill" the same thing.
        label.alignment = .center
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
    /// comment on why this is stored untyped. `nil` pre-26 *and* under
    /// Reduce Transparency, in which case draw(_:) falls back to its
    /// bezier-fill rendering.
    private var glassBackground: NSView?

    /// The selected pill's outline (browser-qpy.1). Selection used to be
    /// expressed purely as a difference in *fill* between this pill and its
    /// neighbours, which only reads when the two differ in luminance -- and
    /// they stop differing precisely when the active page's theme color is
    /// light, because that same color is also blended into the chrome behind
    /// the whole strip (BrowserWindowController.updateChromeTint). An
    /// outline doesn't share that failure mode: it draws the pill's boundary
    /// in a color measured against the pill's own surface, so it stays
    /// legible whatever the backdrop turns out to be -- see
    /// selectionRingTargetContrast for why the pill, and not the backdrop,
    /// is the side that has to be cleared.
    private let selectionRing = CAShapeLayer()

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

        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]
        contentContainer.wantsLayer = true
        selectionRing.fillColor = nil
        selectionRing.lineWidth = Self.selectionRingWidth
        selectionRing.isHidden = true
        contentContainer.layer?.addSublayer(selectionRing)

        rebuildBackground()
        // Reduce Transparency can be toggled while the app is running, and
        // it changes which of the two rendering paths below is correct.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(rebuildBackground),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// `--solid-tab-chrome`: take the non-glass branch of
    /// rebuildBackground() whatever the OS version and whatever Reduce
    /// Transparency says.
    ///
    /// Reduce Transparency lives in `com.apple.universalaccess`, which no
    /// unprivileged process may write -- so the branch it selects is not
    /// reachable from an agent's own test launch, and the selection
    /// treatment there could only ever have been desk-checked. This flag
    /// makes it reachable: it selects the *same* branch by the same code, so
    /// a screenshot taken under it is a real screenshot of that rendering
    /// path, not a mock of one. It says nothing about whether the setting is
    /// read correctly, which still needs the real switch flipped.
    private static let forcesSolidChrome = ProcessInfo.processInfo.arguments.contains("--solid-tab-chrome")

    /// Chooses the pill's background material, and is re-run whenever the
    /// choice could have changed.
    ///
    /// Real Liquid Glass (browser-qpy) hosts contentContainer as its
    /// `contentView` so the favicon/title/buttons render on top of the glass
    /// effect rather than composited underneath it (browser-0y1). Pre-26,
    /// and under Reduce Transparency on any version, there is no glass and
    /// draw(_:) below is the only rendering path -- Reduce Transparency is
    /// new here (browser-qpy.1): this view used to build glass
    /// unconditionally on macOS 26+, ignoring the setting that
    /// GlassBackgroundView has always honored for the chrome behind it.
    @objc private func rebuildBackground() {
        glassBackground?.removeFromSuperview()
        glassBackground = nil
        contentContainer.removeFromSuperview()
        contentContainer.frame = bounds

        if !Self.forcesSolidChrome, !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
           #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.contentView = contentContainer
            addSubview(glass)
            glassBackground = glass
        } else {
            addSubview(contentContainer)
        }
        updateSelectionAppearance()
        needsLayout = true
        needsDisplay = true
    }

    /// Every color below is measured against the *resolved* appearance, so
    /// a light/dark switch has to recompute all of them.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSelectionAppearance()
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    /// `nil` reverts to the generic globe glyph (e.g. a site with no
    /// favicon, or one FaviconLoader couldn't fetch).
    func setFavicon(_ image: NSImage?) {
        faviconView.image = image ?? Self.genericFavicon
    }

    /// A full capsule in the horizontal strip (browser-qpy), a rounded rect
    /// in the sidebar. A capsule only reads as one while the pill is roughly
    /// as wide as it is tall; at a sidebar row's proportions the same radius
    /// turns it into a lozenge, which is why Safari's and Arc's own sidebar
    /// rows are rounded rects and their tab pills are not.
    private var cornerRadius: CGFloat {
        isVerticalLayout ? min(10, bounds.height / 2) : bounds.height / 2
    }

    override func layout() {
        super.layout()
        // Full pill shape (browser-qpy): fully rounded ends at any height,
        // not a fixed radius -- matches the compact pinned width too. On
        // macOS 26+ the real glass view masks its own corners; masking
        // this view's own layer too would double up (and clip nothing
        // extra, since the glass view already fills these bounds).
        if #available(macOS 26.0, *), let glass = glassBackground as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else {
            layer?.cornerRadius = cornerRadius
        }
        layoutSelectionRing()
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
        // Horizontally: the same inset on both sides, so the label's centre
        // is the *pill's* centre and a short title reads as centred in the
        // tab rather than centred in some off-centre gap. The inset is the
        // favicon's own trailing edge, which is the wider of the two things
        // the text must clear (the close button needs less), and it stays
        // constant whether or not the close button is currently showing --
        // otherwise a centred title would visibly shift sideways on hover.
        //
        // Vertically centered as its own row alongside the favicon above
        // (browser-0y1, Brady's ask) -- a plain NSTextField label renders
        // its text top-aligned within whatever frame it's given, so a
        // frame spanning the full tab height (the old behavior) left the
        // title sitting at the top instead of centered. A fixed label
        // height matching the font's own line height, centered the same
        // way faviconView/audioButton already are, fixes that.
        let titleInset = faviconLeading + faviconSize + 6
        let titleHeight: CGFloat = 16
        guard !isVerticalLayout else {
            // A sidebar row reads from its leading edge: the title starts at
            // the favicon's trailing edge and runs to the close button, which
            // gets its space reserved whether or not it is currently showing
            // so a title never reflows on hover.
            titleLabel.frame = NSRect(
                x: titleInset, y: (bounds.height - titleHeight) / 2,
                width: max(0, bounds.width - titleInset - closeSize - 12), height: titleHeight
            )
            return
        }
        titleLabel.frame = NSRect(
            x: titleInset, y: (bounds.height - titleHeight) / 2,
            width: max(0, bounds.width - titleInset * 2), height: titleHeight
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
        if isVerticalLayout {
            updateSelectionAppearance()
        }
        guard !isPinned else { return }
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        if isVerticalLayout {
            updateSelectionAppearance()
        }
        closeButton.isHidden = true
    }

    /// Makes the whole pill one mouse target, apart from its two real buttons.
    ///
    /// Without this, a press lands on whichever subview happens to be under
    /// the pointer -- the `NSGlassEffectView`, its `contentView`, the favicon
    /// `NSImageView`, or (over most of the pill's width) the title
    /// `NSTextField`. Only some of those forward a mouse-down up the responder
    /// chain: `NSTextField` is an `NSControl`, and a control consumes
    /// `mouseDown` in its cell's tracking rather than passing it to the next
    /// responder, so a press starting on the title text reached neither
    /// selection nor a drag. Returning `self` for the whole pill means the
    /// entire mouse sequence -- down, dragged, up -- is delivered here
    /// directly, with no responder-chain forwarding to depend on.
    ///
    /// The close and speaker buttons are deliberately still their own targets;
    /// they must keep receiving their own clicks.
    /// The two nested buttons are matched against their own frames rather than
    /// left to `super.hitTest`, because the glass view doesn't hand its
    /// descendants back either -- a press over the close button resolves to
    /// the `NSGlassEffectView` just like everywhere else on the pill, so
    /// asking `super` "is this the close button?" would always answer no and
    /// quietly make both buttons unclickable. Their frames live in
    /// `contentContainer`, which fills these bounds at the same origin, so
    /// they compare directly against a point in this view's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if !closeButton.isHidden, closeButton.frame.contains(local) { return closeButton }
        if !audioButton.isHidden, audioButton.frame.contains(local) { return audioButton }
        return self
    }

    /// What AppKit's ordinary subview descent returns for `point`, i.e. what
    /// a press here would have landed on before the override above existed.
    /// Recorded by the diagnostics probe so the override's necessity stays
    /// evidence rather than assertion.
    func hitTestIgnoringOverride(_ point: NSPoint) -> NSView? {
        super.hitTest(point)
    }

    /// The close button's centre in this view's coordinates, and whether it's
    /// currently a hit-test candidate -- for the diagnostics probe, which
    /// needs to check the one press the drag work must not break.
    var closeButtonProbePoint: NSPoint { NSPoint(x: closeButton.frame.midX, y: closeButton.frame.midY) }

    /// The frame the point above came from -- logged alongside it so a probe
    /// that measured an un-laid-out button is obvious rather than misread as
    /// a real hit-testing failure.
    var closeButtonProbeFrame: NSRect { closeButton.frame }

    /// Reveals the close button for the duration of `body`, so a probe can ask
    /// what a press over it resolves to without waiting for a real hover.
    func withCloseButtonVisible<T>(_ body: () -> T) -> T {
        let wasHidden = closeButton.isHidden
        closeButton.isHidden = false
        defer { closeButton.isHidden = wasHidden }
        return body()
    }

    /// Identifies a probe's hit result against this pill's own subviews, which
    /// are otherwise private and would just read as "NSButton" in the log.
    func describeHit(_ view: NSView?) -> String {
        switch view {
        case let hit where hit === self: return "TabButtonView"
        case let hit where hit === closeButton: return "closeButton"
        case let hit where hit === audioButton: return "audioButton"
        case let hit?: return String(describing: type(of: hit))
        default: return "nil"
        }
    }

    /// Selection happens on mouse *down*, before any drag is known about --
    /// same as Safari, and what makes "a click that never moved still selects
    /// the tab" fall out for free rather than needing a movement threshold to
    /// resolve first (browser-rhi.6). Dragging a background tab therefore also
    /// activates it, which is again Safari's behavior.
    override func mouseDown(with event: NSEvent) {
        TabDragDiagnostics.record("mouseDown", [
            "tabIndex": index,
            "receiver": String(describing: type(of: self)),
            "isPinned": isPinned,
            "hasDragDelegate": dragDelegate != nil,
            "locationInWindow": TabDragDiagnostics.describe(NSRect(origin: event.locationInWindow, size: .zero)),
            "modifiers": event.modifierFlags.rawValue
        ])
        onSelect?()
        dragDelegate?.tabButton(self, didBeginDragWith: event)
    }

    /// Belt and braces with TabStripView's event monitor: whichever of the two
    /// delivers a given event first wins, and the second is a no-op. The
    /// monitor alone was the original design and shipped not working; rather
    /// than swap one single point of failure for another, both paths are live
    /// and the handlers they call were made idempotent.
    override func mouseDragged(with event: NSEvent) {
        dragDelegate?.tabButton(self, didDragWith: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragDelegate?.tabButton(self, didEndDragWith: event)
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
        if ActiveEngine.capabilities.perTabAudioMute {
            menu.addItem(withTitle: isMuted ? "Unmute Tab" : "Mute Tab", action: #selector(muteToggleTapped), keyEquivalent: "").target = self
        }

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

    // MARK: - Selection appearance (browser-qpy.1)

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

    /// The sidebar's hover wash on the no-glass path (pre-26 / Reduce
    /// Transparency). Between the inactive wash and the selected fill, for
    /// the same reason the glass path stops short of a tint -- see
    /// updateSelectionAppearance().
    private static let hoverWashAlpha: CGFloat = 0.18

    /// An unselected tab's favicon is dimmed, and its title drops to
    /// `.secondaryLabelColor`. These two are the deliberately colorimetry-
    /// free half of browser-qpy.1's fix: they express selected-vs-not
    /// through the *content*, so a difference survives even if every
    /// luminance in play were to coincide exactly.
    private static let inactiveFaviconAlpha: CGFloat = 0.7

    /// Alpha BrowserWindowController.updateChromeTint blends the *active*
    /// tab's theme color into the chrome glass behind the whole strip at.
    /// Restated here rather than shared because this view only needs to
    /// predict the backdrop it is about to be drawn on -- it never sets it.
    /// Knowing that backdrop is the whole point: the selected pill and the
    /// surface behind it are tinted by the same theme color, which is why a
    /// treatment tuned against an untinted backdrop quietly converges with
    /// it as the theme color moves.
    private static let chromeThemeTintAlpha: CGFloat = 0.16

    /// How opaque a `.regular` NSGlassEffectView reads over what's behind
    /// it. An estimate -- AppKit exposes no such number, and the real
    /// material is a blur plus a refraction pass, not a flat composite --
    /// used only to keep the luminance measurements below honest about the
    /// fact that a glass pill is *not* its tint color. Erring low would
    /// overstate the backdrop's influence, erring high would overstate the
    /// tint's; screenshots at both appearance extremes are what settled it.
    private static let regularGlassOpacity: CGFloat = 0.75

    private static let selectionRingWidth: CGFloat = 1.5
    /// The ring is stroked translucent so it reads as an edge of the
    /// material rather than a drawn-on outline. Every contrast figure below
    /// is measured on the ring *composited at this alpha*, not on the pure
    /// candidate color, so the number describes what is actually visible.
    private static let selectionRingAlpha: CGFloat = 0.8

    /// What the selected pill's outline must clear against the pill's own
    /// surface. 3:1 is WCAG 2.1's non-text contrast minimum (SC 1.4.11) --
    /// the right bar for a graphical boundary that conveys state, which is
    /// exactly what this is.
    ///
    /// Measured against the pill and *not* against the backdrop, which is
    /// the property that makes the outline work at any backdrop luminance,
    /// known or not. A ring that matched the backdrop would still outline
    /// the pill perfectly -- the eye simply reads the boundary one pixel
    /// further in, at the high-contrast ring/fill edge. A ring that matched
    /// the *fill* would not: the only remaining edge would be ring against
    /// backdrop, which is precisely the fill-against-backdrop comparison
    /// that fails in this bug. So the fill is the side that must be cleared.
    private static let selectionRingTargetContrast: CGFloat = 3.0

    /// What the selected pill's fill aims for against the strip backdrop.
    /// Deliberately modest: this is surface-against-surface, not text, and
    /// pushing two adjacent chrome materials to 3:1 looks like a rendering
    /// fault. For scale, Safari's own light-mode selected tab sits at about
    /// 1.19:1 against its tab bar and Chrome's at about 1.28:1 -- both lean
    /// on a border/shadow for the rest, as this does on the ring above.
    private static let selectedFillTargetContrast: CGFloat = 1.35

    /// What the selected tab's title must clear against the surface it sits
    /// on -- WCAG AA for normal text. This is what stops a fill flip from
    /// simply moving the problem into the label.
    private static let titleTargetContrast: CGFloat = 4.5

    /// The color of the surface *behind* this pill: the chrome glass, which
    /// carries the active tab's theme color at chromeThemeTintAlpha. Only
    /// meaningful for the selected button, which is the one whose own
    /// themeColorHex *is* the active tab's -- and the only one that asks.
    private var backdropColor: NSColor {
        let base = NSColor.windowBackgroundColor.resolvedSRGB(for: effectiveAppearance)
        guard let hex = themeColorHex, let theme = NSColor(hex: hex) else { return base }
        return theme.composited(alpha: Self.chromeThemeTintAlpha, over: base)
    }

    /// The color the selected pill is filled/tinted with: the standard
    /// control background carrying browser-rhi.5's theme tint, then moved
    /// in luminance until it separates from `backdropColor`. That last step
    /// is the fix -- without it the tint pulls the pill *toward* the same
    /// color the chrome behind it just moved to, so the two converge exactly
    /// when the theme color is strong.
    private var selectedFillColor: NSColor {
        let base = NSColor.controlBackgroundColor.resolvedSRGB(for: effectiveAppearance)
        let tinted = base.tinted(withThemeColorHex: themeColorHex) ?? base
        return tinted.nudged(awayFrom: backdropColor, target: Self.selectedFillTargetContrast)
    }

    /// What the selected pill *renders* as, fill and backdrop combined --
    /// the surface the ring and the title are actually measured against.
    /// Glass is translucent, so its tint color alone would be a poor stand-in.
    private var selectedSurfaceColor: NSColor {
        let fill = selectedFillColor
        guard glassBackground != nil else { return fill }
        return fill.composited(alpha: Self.regularGlassOpacity, over: backdropColor)
    }

    /// Picks the ring color by measurement rather than by assuming the pill
    /// is dark: whichever of near-white/near-black, composited over the
    /// pill's own surface at selectionRingAlpha, lands further from it.
    /// Near- rather than pure, so a light-mode pill gets a legible outline
    /// instead of a hard black line drawn around it.
    private func selectionRingColor(surface: NSColor) -> (color: NSColor, ratio: CGFloat) {
        let light = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let dark = NSColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        var best: (NSColor, CGFloat) = (light, 0)
        for candidate in [light, dark] {
            let ratio = candidate
                .composited(alpha: Self.selectionRingAlpha, over: surface)
                .contrastRatio(against: surface)
            if ratio > best.1 { best = (candidate, ratio) }
        }
        return (best.0.withAlphaComponent(Self.selectionRingAlpha), best.1)
    }

    /// The label/glyph color for `surface`, chosen by measurement for the
    /// same reason the ring is -- point 3 of browser-qpy.1's brief: if the
    /// fill is allowed to flip light, the title has to follow or the bug has
    /// merely moved. Near-white/near-black rather than pure, which costs a
    /// little ratio (still far past titleTargetContrast at both extremes)
    /// and avoids the harshness of full-contrast text on a chrome surface.
    private func foregroundColor(on surface: NSColor) -> NSColor {
        let light = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let dark = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        return light.contrastRatio(against: surface) >= dark.contrastRatio(against: surface) ? light : dark
    }

    override func draw(_ dirtyRect: NSRect) {
        // Whenever a real glass view exists it is the pill's entire
        // material -- see updateSelectionAppearance() for how it reflects
        // isSelected/themeColorHex instead of this fill. This path is what
        // runs pre-26 and under Reduce Transparency (see rebuildBackground).
        guard glassBackground == nil else { return }
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        if isSelected {
            selectedFillColor.setFill()
        } else if isVerticalLayout, isMouseInside {
            NSColor.labelColor.withAlphaComponent(Self.hoverWashAlpha).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(Self.inactiveWashAlpha).setFill()
        }
        path.fill()
    }

    /// Applies the selected/unselected look across every surface that
    /// carries it: the glass material (macOS 26+, non-Reduce-Transparency)
    /// or draw(_:)'s fill, the selection ring, and the title/glyph colors.
    ///
    /// The unselected side is deliberately expressed with cues that don't
    /// depend on any color measurement at all -- a `.clear`/washed pill, a
    /// secondary-label title, a dimmed favicon. That gives the strip a
    /// selected/unselected difference that survives even the case where
    /// every luminance in play happens to coincide.
    private func updateSelectionAppearance() {
        // An unselected sidebar row lifts to the same material on hover, one
        // step short of the selected treatment: no tint, and no selection
        // ring, so it reads as "the pointer is here" rather than as a second
        // selected tab.
        let isHoverHighlighted = isVerticalLayout && isMouseInside && !isSelected
        if #available(macOS 26.0, *), let glass = glassBackground as? NSGlassEffectView {
            glass.style = isSelected || isHoverHighlighted ? .regular : .clear
            glass.tintColor = isSelected ? selectedFillColor : nil
        }
        needsDisplay = true

        guard isSelected else {
            selectionRing.isHidden = true
            titleLabel.textColor = .secondaryLabelColor
            faviconView.alphaValue = Self.inactiveFaviconAlpha
            audioButton.contentTintColor = .secondaryLabelColor
            closeButton.contentTintColor = .secondaryLabelColor
            return
        }

        let surface = selectedSurfaceColor
        selectionRing.isHidden = false
        selectionRing.strokeColor = selectionRingColor(surface: surface).color.cgColor
        let foreground = foregroundColor(on: surface)
        titleLabel.textColor = foreground
        faviconView.alphaValue = 1
        audioButton.contentTintColor = foreground
        closeButton.contentTintColor = foreground
        layoutSelectionRing()
    }

    /// Every measurement the selected treatment is derived from, so the
    /// contrast claims in docs/ai-tasks/tab-selection-contrast-notes.md are
    /// numbers this code actually produced rather than numbers computed
    /// alongside it. Printed per selected tab by TabStripView under
    /// `--tab-contrast-report`; nothing reads it otherwise.
    var selectionContrastReport: String {
        let backdrop = backdropColor
        let fill = selectedFillColor
        let surface = selectedSurfaceColor
        let ring = selectionRingColor(surface: surface)
        let foreground = foregroundColor(on: surface)
        func f(_ value: CGFloat) -> String { String(format: "%.2f", Double(value)) }
        let fields: [(String, String)] = [
            ("tab", String(index)),
            ("themeColor", themeColorHex ?? "none"),
            ("appearance", effectiveAppearance.name.rawValue),
            ("reduceTransparency", String(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)),
            ("glass", String(glassBackground != nil)),
            ("backdrop", backdrop.hexString),
            ("fill", fill.hexString),
            ("surface", surface.hexString),
            ("fillVsBackdrop", f(fill.contrastRatio(against: backdrop))),
            ("surfaceVsBackdrop", f(surface.contrastRatio(against: backdrop))),
            ("ring", ring.color.hexString),
            ("ringRatio", f(ring.ratio)),
            ("ringPass", String(ring.ratio >= Self.selectionRingTargetContrast)),
            ("title", foreground.hexString),
            ("titleRatio", f(foreground.contrastRatio(against: surface))),
            ("titlePass", String(foreground.contrastRatio(against: surface) >= Self.titleTargetContrast))
        ]
        return fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    /// Inset by half the stroke width plus a hair, so the whole stroke lands
    /// inside the pill: `NSGlassEffectView` masks its `contentView` to its
    /// own corner radius, and a ring drawn exactly on the boundary would
    /// have its outer half clipped away on the 26+ path (and only there,
    /// which is the kind of difference that reads as "the ring is thinner in
    /// dark mode" rather than as a clipping bug).
    private func layoutSelectionRing() {
        let inset = Self.selectionRingWidth / 2 + 0.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        guard rect.width > 0, rect.height > 0 else {
            selectionRing.path = nil
            return
        }
        // No implicit animation: the ring must land in its new frame in the
        // same pass as the pill it outlines, or a strip reflow (or a drag)
        // leaves it visibly trailing behind.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionRing.frame = contentContainer.bounds
        // Follows the pill's own radius, so the ring traces the shape it
        // outlines in either orientation rather than bulging past its corners.
        let radius = min(cornerRadius, rect.height / 2)
        selectionRing.path = CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        CATransaction.commit()
    }
}
