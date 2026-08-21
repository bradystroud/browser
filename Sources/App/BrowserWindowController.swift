import AppKit

/// One native window, belonging to exactly one profile (per-window profile
/// identity, see docs/plans/2026-07-27-browser-plan.md). Owns a tab strip, an
/// omnibox + navigation toolbar, and the tabs themselves; only the active
/// tab's hostView is attached to `contentContainerView` at any time, but every
/// tab's BRWBrowser stays alive for the window's lifetime (see Tab.swift).
final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
    TabStripViewDelegate, TabDelegate, NSMenuItemValidation
{
    let profile: Profile

    /// True for a Private Browsing window (browser-12m.1) -- see WindowManager.
    /// openNewPrivateWindow(). `profile` above is still a real (if throwaway,
    /// never-registered-with-ProfileManager) value purely so every existing
    /// piece of this controller that reads `.name`/`.colorHex` keeps working
    /// unchanged; every place that must behave differently for a private
    /// window checks this flag explicitly instead.
    let isPrivate: Bool
    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex: Int?
    /// Every tab group in this window, in section order (see the ordering
    /// invariant documented on `tabs` at moveTab(at:toGroup:)). Pure UI/
    /// session state -- persisted via SessionSnapshot.Group, no engine-side
    /// counterpart. See TabGroup.swift for why membership/order live in
    /// `tabs` (via Tab.groupId) rather than here.
    private(set) var tabGroups: [TabGroup] = []

    /// Set by WindowManager so it can drop this controller from its list.
    var onWindowClosed: (() -> Void)?

    private let initialURL: String

    private let tabStripView = TabStripView(frame: .zero)
    private let toolbarView = NSView()
    /// The unified glass background behind the tab strip + toolbar (browser-
    /// qpy's liquid-glass restyle) -- one continuous vibrant material,
    /// Safari's own "unified toolbar" look, rather than each view tinting
    /// itself separately. Sits behind both (added to contentView first);
    /// falls back to a solid fill under Reduce Transparency (see
    /// GlassBackgroundView).
    private let chromeBackground = GlassBackgroundView(
        material: .underWindowBackground, blendingMode: .behindWindow,
        solidFallbackColor: .windowBackgroundColor
    )
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let omniboxField = OmniboxField()
    /// The omnibox floating pill (browser-qpy): hudWindow material,
    /// withinWindow blending -- differentiates it from the
    /// underWindowBackground chrome it floats on top of (see
    /// chromeBackground). Fixed height, variable width (see
    /// Self.omniboxPillHeight/omniboxCollapsedWidth and omniboxFrame()).
    private let omniboxContainerView = GlassBackgroundView(
        material: .hudWindow, blendingMode: .withinWindow,
        solidFallbackColor: .controlBackgroundColor,
        cornerRadius: BrowserWindowController.omniboxPillHeight / 2
    )
    /// Thin, Safari-style loading-progress bar shown just below the
    /// omnibox pill (browser-7z5, Brady's ask: navigation gave zero
    /// feedback before). Fills as CEF's own real loading-progress signal
    /// advances (Tab.loadingProgress -- a genuine percentage, not a fake/
    /// eased approximation; see EngineTabDelegate.
    /// engineTabDidUpdateLoadingProgress's own doc comment for why no
    /// approximation is needed here), fades out shortly after completion.
    /// A plain NSView whose own frame width *is* the progress -- simpler
    /// than a custom draw(_:), and animates for free via NSAnimationContext
    /// the same way the omnibox pill's own frame already does.
    private let loadingProgressView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        view.layer?.cornerRadius = 1
        view.alphaValue = 0
        return view
    }()
    private static let loadingProgressBarHeight: CGFloat = 2
    /// True while the omnibox field is actually being edited (see
    /// controlTextDidBeginEditing/controlTextDidEndEditing below) -- expands
    /// the pill to show the full editable URL; false shows a narrow,
    /// domain-only pill (see Self.domainOnlyDisplay(for:)).
    private var isOmniboxFocused = false
    /// The pending revert from a transient "Copied to Clipboard" display
    /// (browser-0y1, Brady's ask -- see showCopiedFeedback(for:)) --
    /// cancelled and replaced on every ⌘⇧C press so rapid repeats restart
    /// the same 0.8s countdown instead of stacking reverts.
    private var copiedFeedbackWorkItem: DispatchWorkItem?
    /// The pending fade-out after a navigation's progress bar reaches 100%
    /// (browser-7z5, see updateLoadingProgressBar(for:)) -- cancelled if a
    /// new navigation starts before the fade would have fired, so a rapid
    /// second navigation doesn't have its own fresh progress bar fade away
    /// underneath it because of the *previous* navigation's stale timer.
    private var loadingProgressCompletionWorkItem: DispatchWorkItem?
    private static let omniboxPillHeight: CGFloat = 30
    /// The collapsed (unfocused) pill scales with the window rather than
    /// sitting at one fixed width, which used to leave a full-screen window
    /// showing exactly the same small pill as a half-width one (Brady's ask).
    /// Clamped at both ends: a floor so a narrow window still gets a usable
    /// field, and a ceiling so a very wide display doesn't stretch it into a
    /// full-width bar -- past a point, extra width shows nothing more, since
    /// a URL that long is truncated by the display preference anyway.
    private static let omniboxCollapsedMinWidth: CGFloat = 280
    private static let omniboxCollapsedMaxWidth: CGFloat = 820
    private static let omniboxCollapsedWidthFraction: CGFloat = 0.45
    /// Minimum breathing room between the expanded pill and whatever sits
    /// on either side of it (back/forward on the left, the private-browsing
    /// pill if any on the right).
    private static let omniboxHorizontalMargin: CGFloat = 16
    /// A simple "Private" pill -- the whole visual distinction Private
    /// Browsing gets for now (browser-12m.1). nil (never created) for a
    /// normal window. Anchored off the toolbar's trailing edge.
    private let privateLabel: NSTextField?
    /// Safari-style profile indicator (browser-0y1, Brady's ask): a small
    /// glass pill showing this window's profile color + name, at the
    /// toolbar's leading edge next to navigation -- the chrome tint alone
    /// (browser-qpy point 5) turned out to be too subtle for Brady to
    /// actually tell which profile he's in at a glance. Clicking it offers
    /// switching profiles (see profilePillTapped(_:)) -- always by opening
    /// a *new* window: a window's CefRequestContext is fixed for its
    /// lifetime, so there's no in-place "hot swap" of an existing window's
    /// profile. nil (never created) for a Private window, which has no
    /// real profile identity to indicate.
    private let profilePillButton: NSButton?
    private static let profilePillHeight: CGFloat = 30
    private static let trailingToolbarControlSize: CGFloat = 30
    private static let trailingToolbarControlGap: CGFloat = 6
    private static let trailingToolbarControlCount = 4
    private let contentContainerView = NSView()

    /// The Y coordinate, in window.contentView's own coordinate space, of
    /// the real web content area's top edge -- i.e. immediately below all
    /// chrome (toolbar/omnibox row + tab strip), whichever one of those
    /// currently sits on top. contentContainerView's own [.width, .height]
    /// autoresizing mask keeps its frame correct across window resizes with
    /// no recomputation needed here -- this is just a read of that live
    /// frame, never a cached/duplicated constant.
    ///
    /// NOT a safe home for a floating overlay added directly to
    /// window.contentView: anything positioned *below* this line overlaps
    /// contentContainerView's own bounds, where CEF's own hosted content
    /// view lives, and CEF's compositing surface silently paints over any
    /// AppKit sibling occupying that same region regardless of normal
    /// addSubview z-order -- confirmed by trial (browser-qpy-overlay-notes:
    /// a button positioned here never appeared in a real screenshot, the
    /// identical button positioned above this line, inside the chrome,
    /// rendered immediately). Use toolbarRowHeight below to stay inside the
    /// toolbar band instead, which does render reliably.
    var contentAreaTopY: CGFloat { contentContainerView.frame.maxY }

    /// The toolbar/omnibox row's own height. The toolbar always occupies
    /// the top toolbarRowHeight points of window.contentView regardless of
    /// where the tab strip sits relative to it (see setUpViews), so
    /// `contentView.bounds.height - toolbarRowHeight` is always that band's
    /// own bottom edge -- this is the one safe place left for a small
    /// floating icon overlay (the Reader button, the password/autofill key
    /// & fill icons) to live: unlike the tab strip, it has no per-tab
    /// controls (mute/close) to collide with, and unlike the content area
    /// below contentAreaTopY, it isn't covered by CEF's own compositing.
    /// Stay clear of the far-left (traffic lights, back/forward, the
    /// profile pill -- see layoutProfilePill) and the far-right in a
    /// Private window (privateLabel) when choosing an X position here.
    var toolbarRowHeight: CGFloat { toolbarView.frame.height }

    /// A shared trailing-edge grid for the floating toolbar controls owned by
    /// Reader, Downloads and autofill coordinators. Those features are
    /// intentionally separate controllers, but their buttons still need one
    /// geometry contract or optional controls can overlap each other.
    func trailingToolbarControlFrame(slot: Int) -> NSRect {
        guard let contentView = window?.contentView else { return .zero }
        let size = Self.trailingToolbarControlSize
        let trailingInset: CGFloat = privateLabel == nil ? 10 : 8 + 54 + Self.trailingToolbarControlGap
        return NSRect(
            x: contentView.bounds.width - trailingInset - size
                - CGFloat(slot) * (size + Self.trailingToolbarControlGap),
            y: contentView.bounds.height - (toolbarRowHeight + size) / 2,
            width: size,
            height: size
        )
    }

    private var trailingToolbarControlsReservedWidth: CGFloat {
        let trailingInset: CGFloat = privateLabel == nil ? 10 : 8 + 54 + Self.trailingToolbarControlGap
        return trailingInset
            + Self.trailingToolbarControlSize * CGFloat(Self.trailingToolbarControlCount)
            + Self.trailingToolbarControlGap * CGFloat(Self.trailingToolbarControlCount - 1)
    }

    private let autocomplete = OmniboxAutocompleteController()
    private let permissionPrompt = PermissionPromptController()
    /// ⌘D's Add Bookmark popover (browser-5kq.7) -- see addBookmark(_:).
    private let addBookmarkPrompt = AddBookmarkPromptController()
    /// The content blocker's toolbar shield (browser-12m.5.1.1) -- lives
    /// inside omniboxContainerView's leading edge, mirroring reloadButton's
    /// placement on the trailing edge. Title shows the active tab's
    /// blockedRequestCount when non-zero, icon-only otherwise.
    private let contentBlockerButton = NSButton()
    private let contentBlockerPopover = ContentBlockerToolbarController()
    /// Per-tab page thumbnails for the Tab Overview grid (browser-rhi.3) --
    /// see TabThumbnailCache's doc comment for why capture only ever
    /// happens at deactivation time (captureThumbnail(for:), called from
    /// activateTab below).
    private let thumbnailCache = TabThumbnailCache()
    /// One overview grid per window -- see TabOverviewController's doc
    /// comment for why this isn't a global singleton the way
    /// ShortcutsOverlayController is. `self` is fully initialized by the
    /// time this first actually runs (lazy), even though it's referenced
    /// in its own initializer.
    private lazy var tabOverview = TabOverviewController(windowController: self)
    /// The tab + promptId a permission request is currently showing UI for,
    /// so a CEF-initiated dismiss (engineTabDidDismissPermissionRequest) for
    /// an unrelated/stale promptId doesn't tear down a newer prompt.
    private var pendingPermissionRequest: (tab: Tab, promptId: UInt64)?

    var activeTab: Tab? {
        guard let index = activeTabIndex, tabs.indices.contains(index) else { return nil }
        return tabs[index]
    }

    init(profile: Profile, initialURL: String, isPrivate: Bool = false) {
        self.profile = profile
        self.isPrivate = isPrivate
        self.initialURL = initialURL
        if isPrivate {
            let label = NSTextField(labelWithString: "Private")
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .white
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
            label.layer?.cornerRadius = 8
            self.privateLabel = label
            self.profilePillButton = nil
        } else {
            self.privateLabel = nil
            self.profilePillButton = NSButton()
        }

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = isPrivate ? "Private Browsing" : "Browser — \(profile.name)"
        window.center()
        super.init(window: window)
        window.delegate = self
        setUpViews()
        autocomplete.onCommit = { [weak self] suggestion in
            self?.commitOmniboxNavigation(to: suggestion.url)
        }
        // So a mode change in Settings' General pane is reflected
        // immediately in this window's collapsed omnibox pill, rather than
        // waiting for the active tab's next navigation/title change
        // (browser-0y1) -- see collapsedOmniboxDisplay(for:).
        NotificationCenter.default.addObserver(
            forName: .omniboxDisplayPreferenceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let tab = self.activeTab, !self.isOmniboxFocused else { return }
            self.omniboxField.stringValue = Self.collapsedOmniboxDisplay(for: tab)
        }
        // So the profile pill picks up a rename/recolor of this window's
        // own profile done elsewhere (e.g. the Settings Profiles pane)
        // while this window is open.
        NotificationCenter.default.addObserver(
            forName: .profileManagerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateProfilePillContent()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Orders the window on screen and creates the first tab's CEF browser.
    /// Mirrors the M0 spike's ordering (window on screen, then CreateBrowser)
    /// deliberately -- SetAsChild needs the host view's real frame.
    ///
    /// Under --test-no-activate (contained testing, see CommandLineArgs),
    /// the window is moved off the visible screen frame and ordered in
    /// without becoming key -- a real NSWindow with a real frame (so
    /// SetAsChild's bounds are still valid and every close path is still
    /// exercised for real), just invisible and focus-neutral on the actual
    /// display.
    ///
    /// `restoring`/`groups`/`activeIndex`, when non-empty, recreate a
    /// session-restored window's tabs (and tab groups) instead of the usual
    /// single `initialURL` tab -- see WindowManager.restoreSession. All
    /// restored tabs are added inactive first and only the designated active
    /// one is then explicitly activated, so inactive tabs' CefBrowsers stay
    /// lazily uncreated until the user actually clicks over to one
    /// (Tab.createBrowserIfNeeded is a no-op until then) -- restoring 20
    /// background tabs doesn't spin up 20 CefBrowsers at launch. Each also
    /// skips the "new tab focuses omnibox" UX (Tab.needsInitialOmniboxFocus)
    /// -- that's for a user deliberately opening a new tab, not an automatic
    /// relaunch.
    func show(restoring restoreTabs: [SessionSnapshot.Tab] = [], groups restoreGroups: [SessionSnapshot.Group] = [], activeIndex: Int = 0) {
        if CommandLineArgs.testNoActivate() {
            window?.setFrameOrigin(NSPoint(x: -3000, y: -3000))
            window?.orderBack(nil)
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
        guard tabs.isEmpty else { return }

        guard !restoreTabs.isEmpty else {
            addTab(url: initialURL, makeActive: true)
            return
        }

        tabGroups = restoreGroups.map { TabGroup(id: $0.id, name: $0.name, colorHex: $0.colorHex, isCollapsed: $0.isCollapsed) }

        for restoreTab in restoreTabs {
            let tab = addTab(url: restoreTab.url, makeActive: false)
            tab.needsInitialOmniboxFocus = false
            tab.seedRestoredTitle(restoreTab.title)
            tab.isPinned = restoreTab.isPinned
            tab.groupId = restoreTab.groupId
        }
        // Defensive: the [pinned][group sections][loose] ordering invariant
        // every other pin/unpin/group/index operation in this class relies
        // on is only guaranteed for state this class itself produced -- a
        // hand-edited or otherwise malformed session.json could have tabs
        // out of section order. A stable sort (Swift's sort is stable) here
        // costs nothing and guarantees the strip renders correctly from the
        // first frame regardless. Tracked by object (not index) through the
        // sort, since sorting can move the persisted activeIndex's tab
        // elsewhere.
        let requestedActiveTab = tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
        let groupOrder = Dictionary(uniqueKeysWithValues: tabGroups.enumerated().map { ($1.id, $0) })
        tabs.sort { sectionKey(for: $0, groupOrder: groupOrder) < sectionKey(for: $1, groupOrder: groupOrder) }
        let validIndex = requestedActiveTab.flatMap { tab in tabs.firstIndex { $0 === tab } } ?? 0
        tabStripView.reload(tabs: currentDisplayInfos, groups: currentGroupDisplayInfos, selectedIndex: validIndex)
        activateTab(at: validIndex)
    }

    /// Sort key for show(restoring:)'s defensive reorder: 0 = pinned,
    /// 1...N = grouped (by the group's position in tabGroups, so multiple
    /// groups' sections land in the right relative order too), N+1 = loose/
    /// ungrouped. Ties (same section) preserve original relative order,
    /// since Swift's sort is stable.
    private func sectionKey(for tab: Tab, groupOrder: [UUID: Int]) -> Int {
        if tab.isPinned { return 0 }
        if let groupId = tab.groupId, let position = groupOrder[groupId] { return 1 + position }
        return groupOrder.count + 1
    }

    private var currentDisplayInfos: [TabStripView.DisplayInfo] {
        tabs.map {
            TabStripView.DisplayInfo(
                // displayTitle, not title (browser-7z5) -- see
                // tabDidChangeDisplayState(_:)'s own comment for why.
                title: $0.displayTitle, favicon: $0.faviconImage, isPinned: $0.isPinned,
                groupId: $0.groupId, themeColorHex: $0.themeColorHex,
                isMuted: $0.isMuted, isAudible: $0.isAudible, isLoading: $0.isLoading)
        }
    }

    private var currentGroupDisplayInfos: [TabStripView.GroupDisplayInfo] {
        tabGroups.map { TabStripView.GroupDisplayInfo(id: $0.id, name: $0.name, colorHex: $0.colorHex, isCollapsed: $0.isCollapsed) }
    }

    // MARK: - View setup

    /// Space reserved at the toolbar row's leading edge for the traffic-
    /// light buttons, which float over this area now that the titlebar is
    /// hidden (browser-qpy) -- wide enough to clear them at any window
    /// size (they don't move), a touch more generous than their tightest
    /// possible fit. Was the tab strip's own leadingInset until browser-0y1
    /// flipped the chrome order (toolbar/omnibox row now on top, tab strip
    /// below it -- Brady's ask, matching where the traffic lights actually
    /// float once the order changes); TabStripView.leadingInset now stays
    /// at its default 0.
    private static let trafficLightReservedWidth: CGFloat = 78

    private func setUpViews() {
        guard let window, let contentView = window.contentView else { return }
        let tabStripHeight: CGFloat = 32
        // Was 36 -- left only 3pt above/below the 30pt-tall omnibox pill,
        // which read as "almost touching the content" (Brady's report,
        // browser-0y1) even before the chrome-order flip changed what
        // technically sits directly below it. 44 gives the pill visible,
        // symmetric breathing room (7pt each side), closer to Safari's own
        // proportions. Everything else in this method/setUpToolbarContents/
        // omniboxFrame derives from this one constant (via
        // toolbarView.bounds.height), so nothing else needs updating.
        let toolbarHeight: CGFloat = 44
        let chromeHeight = tabStripHeight + toolbarHeight

        // Hidden titlebar + full-size content view (browser-qpy): the
        // toolbar row effectively becomes the titlebar area, with the
        // traffic lights floating over its leading edge (see
        // Self.trafficLightReservedWidth, applied in setUpToolbarContents/
        // expandedOmniboxWidth below).
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)

        chromeBackground.frame = NSRect(
            x: 0,
            y: contentView.bounds.height - chromeHeight,
            width: contentView.bounds.width,
            height: chromeHeight
        )
        chromeBackground.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(chromeBackground)

        // Toolbar/omnibox row now on top (browser-0y1) -- was below the tab
        // strip before.
        toolbarView.frame = NSRect(
            x: 0,
            y: contentView.bounds.height - toolbarHeight,
            width: contentView.bounds.width,
            height: toolbarHeight
        )
        toolbarView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(toolbarView)
        setUpToolbarContents()

        // Tab strip now below the toolbar -- no longer needs leadingInset
        // (stays at its default 0), since the traffic lights float over the
        // toolbar row above it instead.
        tabStripView.frame = NSRect(
            x: 0,
            y: contentView.bounds.height - toolbarHeight - tabStripHeight,
            width: contentView.bounds.width,
            height: tabStripHeight
        )
        tabStripView.autoresizingMask = [.width, .minYMargin]
        tabStripView.delegate = self
        contentView.addSubview(tabStripView)

        contentContainerView.frame = NSRect(
            x: 0,
            y: 0,
            width: contentView.bounds.width,
            height: contentView.bounds.height - tabStripHeight - toolbarHeight
        )
        contentContainerView.autoresizingMask = [.width, .height]
        contentContainerView.wantsLayer = true
        contentView.addSubview(contentContainerView)
    }

    private func setUpToolbarContents() {
        let buttonSize: CGFloat = 28
        let margin: CGFloat = 8
        // Traffic lights float over this toolbar row now (browser-0y1's
        // chrome-order flip put it on top) -- back/forward start clear of
        // them, not at the bare left margin. Only the leading edge needs
        // this; the trailing edge (privateLabel below) still uses the
        // plain margin.
        let leadingMargin: CGFloat = margin + Self.trafficLightReservedWidth
        let gap: CGFloat = 4
        let toolbarHeight = toolbarView.bounds.height

        backButton.frame = NSRect(x: leadingMargin, y: (toolbarHeight - buttonSize) / 2, width: buttonSize, height: buttonSize)
        backButton.applyChromeAppearance(.inline)
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        // Navigation stays visually quiet on the unified glass, but uses a
        // native toolbar bezel on hover instead of providing no response.
        backButton.toolTip = "Back"
        backButton.target = self
        backButton.action = #selector(goBackAction(_:))
        toolbarView.addSubview(backButton)

        forwardButton.frame = NSRect(
            x: leadingMargin + buttonSize + gap,
            y: (toolbarHeight - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )
        forwardButton.applyChromeAppearance(.inline)
        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardButton.toolTip = "Forward"
        forwardButton.target = self
        forwardButton.action = #selector(goForwardAction(_:))
        toolbarView.addSubview(forwardButton)

        // Profile indicator pill (browser-0y1) -- right after navigation,
        // matching Safari's own placement. nil for a Private window (see
        // this controller's init).
        if let profilePillButton {
            profilePillButton.applyChromeAppearance(.glass)
            profilePillButton.imagePosition = .imageLeading
            profilePillButton.font = .systemFont(ofSize: 13, weight: .medium)
            profilePillButton.target = self
            profilePillButton.action = #selector(profilePillTapped(_:))
            profilePillButton.toolTip = "Switch Profile"
            toolbarView.addSubview(profilePillButton)

            updateProfilePillContent()
            layoutProfilePill()
        }

        if let privateLabel {
            let labelSize = CGSize(width: 54, height: 18)
            privateLabel.frame = NSRect(
                x: toolbarView.bounds.width - margin - labelSize.width,
                y: (toolbarHeight - labelSize.height) / 2,
                width: labelSize.width,
                height: labelSize.height
            )
            privateLabel.autoresizingMask = [.minXMargin]
            toolbarView.addSubview(privateLabel)
        }

        // Omnibox pill (browser-qpy): a centered floating capsule, domain-
        // only when unfocused, expanding to the full editable URL on focus/
        // ⌘L (see setOmniboxFocused(_:animated:)) -- reload lives inside its
        // trailing edge, not as a separate toolbar button.
        omniboxContainerView.layer?.borderWidth = 0.5
        omniboxContainerView.layer?.borderColor = NSColor.separatorColor.cgColor
        omniboxContainerView.shadow = NSShadow()
        omniboxContainerView.layer?.shadowOpacity = 0.15
        omniboxContainerView.layer?.shadowRadius = 4
        omniboxContainerView.layer?.shadowOffset = NSSize(width: 0, height: -1)
        toolbarView.addSubview(omniboxContainerView)

        omniboxField.isBordered = false
        omniboxField.drawsBackground = false
        omniboxField.focusRingType = .none
        omniboxField.placeholderString = "Search or enter website name"
        omniboxField.target = self
        omniboxField.action = #selector(omniboxSubmitted)
        omniboxField.delegate = self
        // "Move Tab to Profile" (browser-0y1) -- appended to the field's
        // own standard cut/copy/paste context menu, not a replacement for
        // it. Kept as a closure set here rather than a full delegate
        // protocol, matching OmniboxField's own doc comment.
        omniboxField.onBuildContextMenu = { [weak self] menu in
            guard let self else { return }
            menu.addItem(.separator())
            menu.addItem(self.moveToProfileMenuItem())
        }
        // Focus (a click or ⌘L) swaps the collapsed display for the full,
        // selected URL -- see OmniboxField.becomeFirstResponder().
        omniboxField.expandedTextProvider = { [weak self] in self?.activeTab?.urlString }
        // Real content lives in contentContainer, not omniboxContainerView
        // itself (browser-0y1) -- see GlassBackgroundView.contentContainer's
        // own doc comment for why a plain sibling subview of the glass view
        // isn't guaranteed correct z-ordering.
        omniboxContainerView.contentContainer.addSubview(omniboxField)

        // browser-12m.5.1.1 -- hidden until refreshContentBlockerButton(for:)
        // has something to show (see that method's own doc comment).
        contentBlockerButton.applyChromeAppearance(.inline)
        contentBlockerButton.imagePosition = .imageLeading
        contentBlockerButton.font = .systemFont(ofSize: 11)
        contentBlockerButton.target = self
        contentBlockerButton.action = #selector(toggleContentBlockerPopover(_:))
        contentBlockerButton.isHidden = true
        omniboxContainerView.contentContainer.addSubview(contentBlockerButton)

        reloadButton.applyChromeAppearance(.inline)
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.toolTip = "Reload"
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage(_:))
        omniboxContainerView.contentContainer.addSubview(reloadButton)

        // Sits in the toolbar's own padding below the pill (browser-0y1's
        // breathing-room fix left room for exactly this) -- not inside
        // omniboxContainerView itself, so it isn't clipped to the pill's
        // rounded corners or affected by its glass material.
        toolbarView.addSubview(loadingProgressView)

        layoutOmniboxContainer()
    }

    /// The pill's outer frame -- centered in the toolbar, width depending on
    /// isOmniboxFocused. Called from setUpToolbarContents, windowDidResize,
    /// and setOmniboxFocused(_:animated:).
    private func omniboxFrame() -> NSRect {
        let toolbarHeight = toolbarView.bounds.height
        let width = isOmniboxFocused ? expandedOmniboxWidth() : collapsedOmniboxWidth()
        let x = (toolbarView.bounds.width - width) / 2
        return NSRect(x: x, y: (toolbarHeight - Self.omniboxPillHeight) / 2, width: width, height: Self.omniboxPillHeight)
    }

    /// The unfocused pill's width for the current window size -- see
    /// omniboxCollapsedWidthFraction.
    private func collapsedOmniboxWidth() -> CGFloat {
        let proportional = toolbarView.bounds.width * Self.omniboxCollapsedWidthFraction
        let clamped = min(Self.omniboxCollapsedMaxWidth, max(Self.omniboxCollapsedMinWidth, proportional))
        // Never wider than the focused pill: expandedOmniboxWidth() is what
        // actually fits between back/forward and the private-browsing pill, so
        // a collapsed pill past it would both overlap them and, absurdly,
        // *shrink* when clicked into.
        return min(clamped, expandedOmniboxWidth())
    }

    /// How wide the expanded pill can get before it would crowd navigation /
    /// profile controls on the left or floating toolbar controls (and the
    /// Private label, if present) on the right -- never narrower than the
    /// collapsed minimum even in a very small window.
    private func expandedOmniboxWidth() -> CGFloat {
        let margin: CGFloat = 8
        let buttonSize: CGFloat = 28
        let gap: CGFloat = 4
        // Traffic lights float over this row's leading edge now
        // (browser-0y1) -- back/forward already start past them (see
        // setUpToolbarContents), so the expanded pill must stop there too.
        // The profile pill (also browser-0y1) sits right after them.
        let profilePillReserved = profilePillButton.map { $0.frame.width + gap } ?? 0
        let leadingReserved = margin + Self.trafficLightReservedWidth + (buttonSize + gap) * 2 + profilePillReserved + Self.omniboxHorizontalMargin
        let trailingReserved = trailingToolbarControlsReservedWidth + Self.omniboxHorizontalMargin
        return max(Self.omniboxCollapsedMinWidth, toolbarView.bounds.width - leadingReserved - trailingReserved)
    }

    /// Repositions the pill itself (not animated -- see
    /// setOmniboxFocused(_:animated:), the only place that needs the
    /// animated variant) and its inner content (the field + trailing reload
    /// button, which never animate, only snap to their new size).
    private func layoutOmniboxContainer() {
        omniboxContainerView.frame = omniboxFrame()
        layoutOmniboxInnerContent()
        layoutLoadingProgressTrack()
    }

    /// Repositions the progress bar's track (x/y/height, tied to the
    /// omnibox pill's own current frame) without touching its current
    /// fill width -- that's owned by updateLoadingProgressBar(for:), the
    /// only place that animates it based on Tab.loadingProgress. Called
    /// whenever the pill itself moves/resizes (window resize, focus
    /// expand/collapse) so the bar always tracks the pill's current x
    /// position and width even if the fill animation isn't mid-flight.
    private func layoutLoadingProgressTrack() {
        let barY: CGFloat = 2
        let currentFillWidth = loadingProgressView.frame.width
        loadingProgressView.frame = NSRect(
            x: omniboxContainerView.frame.minX, y: barY,
            width: min(currentFillWidth, omniboxContainerView.frame.width),
            height: Self.loadingProgressBarHeight
        )
    }

    private func layoutOmniboxInnerContent() {
        let width = omniboxContainerView.frame.width
        let reloadSize: CGFloat = 20
        let innerMargin: CGFloat = 8
        reloadButton.frame = NSRect(
            x: width - reloadSize - innerMargin, y: (Self.omniboxPillHeight - reloadSize) / 2,
            width: reloadSize, height: reloadSize
        )
        // Only occupies real width once it actually has something to show
        // (see refreshContentBlockerButton) -- otherwise 0-width so the
        // field's leading edge doesn't leave an empty gap on an ordinary
        // page with nothing blocked.
        let blockerWidth = contentBlockerButton.isHidden ? 0 : contentBlockerButton.frame.width
        contentBlockerButton.frame = NSRect(
            x: innerMargin, y: (Self.omniboxPillHeight - 20) / 2,
            width: blockerWidth, height: 20
        )
        let fieldX = innerMargin + blockerWidth + (blockerWidth > 0 ? 4 : 0)
        // A borderless NSTextField draws its single line at the top of an
        // oversized frame. Size the field to its real one-line height, then
        // center that frame in the pill so both the empty placeholder and
        // the focused/editable URL share the same vertically centred baseline.
        let fieldHeight = omniboxField.intrinsicContentSize.height
        omniboxField.frame = NSRect(
            x: fieldX, y: (Self.omniboxPillHeight - fieldHeight) / 2,
            width: max(0, width - fieldX - innerMargin - reloadSize - 4), height: fieldHeight
        )
    }

    /// Just the host, e.g. "example.com" -- what the pill shows while
    /// collapsed/unfocused in .domainOnly mode (the default). Falls back to
    /// the raw string if it does not parse as a URL with a host (e.g.
    /// "about:blank", or the empty string shown for the internal start
    /// page -- see Tab.urlString).
    private static func domainOnlyDisplay(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return urlString }
        return host
    }

    /// What the omnibox pill shows while collapsed/unfocused, per
    /// OmniboxDisplayPreference (browser-0y1, Brady's ask) -- always the
    /// full editable URL while focused/being edited, regardless of this
    /// setting (see setOmniboxFocused(_:animated:), the only place that
    /// ever shows the focused/full-URL form).
    private static func collapsedOmniboxDisplay(for tab: Tab) -> String {
        // Prefer the optimistic pending-navigation URL over the tab's real
        // committed one (browser-7z5) -- the whole point is instant
        // feedback the moment a click/Enter registers, not waiting for the
        // real navigation to land.
        let effectiveURLString = tab.pendingNavigationURL ?? tab.urlString
        switch OmniboxDisplayPreference.current {
        case .domainOnly:
            return domainOnlyDisplay(for: effectiveURLString)
        case .pageTitle:
            // No real title exists yet for a pending navigation -- same
            // "show the target host, not a stale title" reasoning as
            // Tab.displayTitle. An empty title (e.g. a committed page that
            // hasn't reported one yet) falls back the same way.
            guard tab.pendingNavigationURL == nil, !tab.title.isEmpty else {
                return domainOnlyDisplay(for: effectiveURLString)
            }
            return tab.title
        case .fullURL:
            // Strips only the "https://" scheme -- "http://" is deliberately
            // kept visible (a security nicety: an insecure site should
            // still visibly announce itself as such, even in the compact
            // display -- see the Settings help text for this preference).
            guard effectiveURLString.hasPrefix("https://") else { return effectiveURLString }
            return String(effectiveURLString.dropFirst("https://".count))
        }
    }

    // MARK: - Profile pill (browser-0y1)

    /// Re-reads this window's profile fresh from ProfileManager (by id, not
    /// `self.profile` directly) since `Profile` is a value type -- `profile`
    /// is a snapshot from whenever this window was created/last refreshed,
    /// so a rename/recolor done elsewhere wouldn't otherwise be reflected
    /// (see the .profileManagerDidChange observer in init).
    private func updateProfilePillContent() {
        guard let profilePillButton else { return }
        let current = ProfileManager.shared.profile(id: profile.id) ?? profile
        profilePillButton.image = Self.dotImage(colorHex: current.colorHex, diameter: 12)
        profilePillButton.title = current.name
        layoutProfilePill()
    }

    /// Sizes/positions the pill to fit its current content, right after
    /// forwardButton (already laid out by the time this runs -- see
    /// setUpToolbarContents). Also re-run whenever the content changes
    /// (a rename can change the button's fitted width).
    private func layoutProfilePill() {
        guard let profilePillButton else { return }
        profilePillButton.sizeToFit()
        let gap: CGFloat = 8
        let pillWidth = max(44, profilePillButton.frame.width)
        let toolbarHeight = toolbarView.bounds.height
        profilePillButton.frame = NSRect(
            x: forwardButton.frame.maxX + gap,
            y: (toolbarHeight - Self.profilePillHeight) / 2,
            width: pillWidth,
            height: Self.profilePillHeight
        )
    }

    /// Small solid-colored circle, e.g. for the profile pill and its
    /// switch-profile menu -- not a template image, so its actual color
    /// renders rather than being tinted to a single color by whatever
    /// `contentTintColor`/menu styling would otherwise apply.
    private static func dotImage(colorHex: String, diameter: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter))
        image.lockFocus()
        (NSColor(hex: colorHex) ?? .controlAccentColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Offers switching to a different profile -- always a new window (see
    /// the profile indicator's doc comment above for why there's no in-place
    /// hot swap). Built fresh each time so it always reflects the current
    /// profile list/current selection, same reasoning as TabButtonView's
    /// own context menu.
    @objc private func profilePillTapped(_ sender: NSButton) {
        let menu = NSMenu()
        for candidate in ProfileManager.shared.profiles {
            let item = NSMenuItem(title: candidate.name, action: #selector(switchToProfileMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate
            item.image = Self.dotImage(colorHex: candidate.colorHex, diameter: 10)
            item.state = candidate.id == profile.id ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "New Profile…", action: #selector(newProfileFromPillMenu), keyEquivalent: "").target = self
        // Second entry point for the same command as the omnibox's own
        // context menu (browser-0y1, Brady's ask -- "two natural entry
        // points").
        menu.addItem(.separator())
        menu.addItem(moveToProfileMenuItem())
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// A no-op for the current window's own profile (there's nothing to
    /// switch to) -- opens a new window for any other profile.
    @objc private func switchToProfileMenuItem(_ sender: NSMenuItem) {
        guard let candidate = sender.representedObject as? Profile, candidate.id != profile.id else { return }
        WindowManager.shared.openNewWindow(profile: candidate)
    }

    /// Reuses AppDelegate's own "New Profile…" action (same prompt, same
    /// rebuildProfilesMenu + openNewWindow sequence as the app menu's own
    /// Profiles > New Profile… item) rather than duplicating that sequence
    /// here.
    @objc private func newProfileFromPillMenu() {
        (NSApp.delegate as? AppDelegate)?.newProfilePrompt(nil)
    }

    /// "Move Tab to Profile ▸ <other profiles>" (browser-0y1, Brady's ask)
    /// -- shared by the omnibox's own right-click context menu
    /// (OmniboxField.onBuildContextMenu) and the profile pill's menu
    /// above, its two natural entry points. Excludes this window's own
    /// profile (nothing to move to). Built fresh each time, same reasoning
    /// as profilePillTapped(_:)/TabButtonView's own context menu. Disabled
    /// (not omitted) when there's no other profile to offer, so the
    /// command stays discoverable even with only one profile.
    private func moveToProfileMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Move Tab to Profile", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let others = ProfileManager.shared.profiles.filter { $0.id != profile.id }
        for candidate in others {
            let candidateItem = NSMenuItem(title: candidate.name, action: #selector(moveActiveTabToProfileMenuItem(_:)), keyEquivalent: "")
            candidateItem.target = self
            candidateItem.representedObject = candidate
            candidateItem.image = Self.dotImage(colorHex: candidate.colorHex, diameter: 10)
            submenu.addItem(candidateItem)
        }
        item.submenu = submenu
        item.isEnabled = !others.isEmpty
        return item
    }

    @objc private func moveActiveTabToProfileMenuItem(_ sender: NSMenuItem) {
        guard let destination = sender.representedObject as? Profile else { return }
        moveActiveTab(toProfile: destination)
    }

    /// Moves the active tab to a different profile -- always via a new tab
    /// in that profile's window (opening one if none exists yet), reusing
    /// RoutingCoordinator's own "find or create a window for this profile"
    /// path rather than a parallel implementation, per the task's own
    /// note: a moved tab should land exactly where a routed link would. A
    /// move, not a copy -- the source tab (and, if it was this window's
    /// last tab, the window itself) closes afterwards; closeTab(at:)
    /// already handles that case, no special-casing needed here.
    ///
    /// SECURITY/PRIVACY: deliberately carries only the URL, never cookies
    /// or session state -- the destination profile's own sign-in state (or
    /// lack of one) is exactly the point of profile isolation. A future
    /// change attempting to carry session state across profiles would
    /// defeat that; don't add one.
    private func moveActiveTab(toProfile destination: Profile) {
        guard let tab = activeTab, let sourceIndex = activeTabIndex else { return }
        RoutingCoordinator.shared.openURL(tab.urlString, in: destination)
        closeTab(at: sourceIndex)
    }

    /// Expands/collapses the pill and swaps the field's displayed text
    /// between the full editable URL (focused) and just the domain
    /// (unfocused) -- called from controlTextDidBeginEditing/
    /// controlTextDidEndEditing below (so both a click into the field and
    /// ⌘L's makeFirstResponder call trigger it identically) and from
    /// commitOmniboxNavigation/Escape's own makeFirstResponder(nil) calls,
    /// which resign the field the same way.
    /// `updatesText: false` expands/collapses the pill without touching what
    /// the field currently displays. That matters when the transition was
    /// triggered by the user *typing*: NSTextField begins an editing session
    /// on the first keystroke, so rewriting stringValue here would throw away
    /// the character they just typed and put the current page's URL back,
    /// leaving Enter to "navigate" to the page already open. The full URL is
    /// instead written explicitly by focusOmnibox(_:), the one place focus is
    /// taken programmatically (⌘L / a new tab), before the editor exists.
    private func setOmniboxFocused(_ focused: Bool, animated: Bool, updatesText: Bool = true) {
        guard isOmniboxFocused != focused else { return }
        isOmniboxFocused = focused
        if updatesText, let tab = activeTab {
            omniboxField.stringValue = focused ? tab.urlString : Self.collapsedOmniboxDisplay(for: tab)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                omniboxContainerView.animator().frame = omniboxFrame()
            }
        } else {
            omniboxContainerView.frame = omniboxFrame()
        }
        layoutOmniboxInnerContent()
    }

    // MARK: - Tabs

    @discardableResult
    func addTab(url: String, makeActive: Bool) -> Tab {
        insertTab(url: url, makeActive: makeActive, at: tabs.count, focusOmnibox: makeActive)
    }

    /// Opens `url` as a new tab immediately after `openerIndex` -- standard
    /// "a link click opens a new tab next to this one" placement, the
    /// target for target="_blank" links and window.open() calls that CEF's
    /// OnBeforePopup would otherwise satisfy with a whole separate native
    /// window (see BRWClientHandler.mm and Tab.engineTabDidRequestNewTab).
    /// Falls back to the pinned/grouped section boundary when the opener is
    /// pinned or grouped, so a plain (unpinned, ungrouped) new tab never
    /// lands inside either section -- see the [pinned][group sections]
    /// [loose] ordering invariant documented on `tabs` elsewhere in this file
    /// (movePinState/moveTab(at:toGroup:)). Unlike addTab(url:makeActive:)
    /// above, never focuses the omnibox: this tab already has real content
    /// to load, not a blank page waiting for a typed URL.
    @discardableResult
    func openTabForLinkClick(url: String, afterIndex openerIndex: Int, foreground: Bool) -> Tab {
        insertTab(url: url, makeActive: foreground, at: insertionIndex(afterOpenerAt: openerIndex), focusOmnibox: false)
    }

    private func insertionIndex(afterOpenerAt openerIndex: Int) -> Int {
        guard tabs.indices.contains(openerIndex) else { return tabs.count }
        let opener = tabs[openerIndex]
        if opener.isPinned {
            return tabs.filter { $0.isPinned }.count
        }
        if let groupId = opener.groupId, let lastInGroup = tabs.lastIndex(where: { $0.groupId == groupId }) {
            return lastInGroup + 1
        }
        return openerIndex + 1
    }

    @discardableResult
    private func insertTab(url: String, makeActive: Bool, at index: Int, focusOmnibox: Bool) -> Tab {
        // Captured before inserting: an insertion at or before the current
        // active index (possible when a background tab -- not the visible
        // one -- is the opener) would otherwise silently shift which tab
        // activeTabIndex points at. Recomputing by object identity afterward
        // is the same guard reloadAfterReorder uses for the same reason.
        let activeTabObject = activeTab
        let tab = Tab(profileName: profile.name, profileId: profile.id, initialURL: url, isPrivate: isPrivate)
        tab.delegate = self
        let clampedIndex = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: clampedIndex)
        // Deliberately before activateTab below, which is what calls
        // Tab.createBrowserIfNeeded: every observer that wires per-tab
        // plumbing (PageMessageDispatcher above all) is therefore wired
        // before this tab has an engine-side browser at all, let alone a page
        // that could send a message into it. See browser-g6d.
        TabLifecycleCenter.shared.post(.opened, tab: tab, in: self)
        if makeActive {
            activateTab(at: clampedIndex)
        } else {
            activeTabIndex = activeTabObject.flatMap { obj in tabs.firstIndex { $0 === obj } }
        }
        tabStripView.reload(
            tabs: currentDisplayInfos,
            groups: currentGroupDisplayInfos,
            selectedIndex: activeTabIndex ?? clampedIndex
        )
        if makeActive && focusOmnibox {
            // New tabs (Cmd+T, the tab strip's "+" button, and a new
            // window's first tab via show()) land in the omnibox with its
            // text selected, ready to type a URL -- standard browser
            // behavior. Tab-switching between existing tabs (selectTab)
            // deliberately doesn't do this -- only genuinely new tabs.
            //
            // Deferred a run-loop turn: called synchronously here, the
            // field's selection reliably doesn't stick (focus does, but the
            // select-all silently doesn't survive whatever AppKit/CEF
            // window-settling happens moments later) -- confirmed by
            // reproducing a fresh tab ending up focused-but-unselected.
            // needsInitialOmniboxFocus's re-assertion below is the more
            // important guard against CEF's own focus grab; this immediate
            // call is a fast-path for the common case where that race
            // doesn't happen at all.
            DispatchQueue.main.async { [weak self] in
                self?.focusOmnibox(nil)
            }
        }
        WindowManager.shared.scheduleSessionSave()
        return tab
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        activateTab(at: index)
    }

    private func activateTab(at index: Int, updateStrip: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        autocomplete.dismiss()
        dismissPermissionPromptIfShowing()

        if let currentIndex = activeTabIndex, tabs.indices.contains(currentIndex) {
            captureThumbnail(for: tabs[currentIndex])
            tabs[currentIndex].hostView.removeFromSuperview()
        }

        activeTabIndex = index
        let tab = tabs[index]

        tab.hostView.frame = contentContainerView.bounds
        tab.hostView.autoresizingMask = [.width, .height]
        contentContainerView.addSubview(tab.hostView)

        // Safe to call every time: a no-op once the browser already exists.
        tab.createBrowserIfNeeded()

        if updateStrip {
            tabStripView.updateSelection(index)
        }
        // refreshToolbar's own currentEditor() == nil guard exists to avoid
        // clobbering a live, in-progress edit -- appropriate while staying on
        // the *same* tab (a display-state ping from the page shouldn't steal
        // whatever the user is mid-typing), but wrong here: index is always a
        // genuinely different tab per selectTab's own guard above it, so any
        // editor session still attached at this point belongs to the tab we
        // just switched away from, not this one. Left alone, that guard would
        // skip repopulating the field and leave the *previous* tab's stale
        // (possibly mid-edit) text on screen -- most visibly, every
        // genuinely-new tab (insertTab's own focusOmnibox path below) would
        // inherit and re-select whatever text was already sitting there
        // instead of its own URL, since focusOmnibox only selects, never
        // sets, the field's text. Ending the stale session here (a no-op if
        // nothing was being edited, and harmless if the omnibox wasn't first
        // responder at all -- makeFirstResponder(nil) only resigns whatever
        // currently *is* first responder) lets refreshToolbar populate the
        // field with the tab we're actually switching to.
        if omniboxField.currentEditor() != nil {
            window?.makeFirstResponder(nil)
        }
        refreshToolbar(for: tab)
        updateWindowTitle(for: tab)
        TabLifecycleCenter.shared.post(.becameActive, tab: tab, in: self)
    }

    /// Snapshots `tab`'s current on-screen appearance into thumbnailCache,
    /// for the Tab Overview grid (browser-rhi.3). Must be called *before*
    /// removing hostView from its superview -- NSView.cacheDisplay(in:to:)
    /// needs the view still attached to a window to paint reliably; a
    /// detached view's cached display is undefined/stale (see
    /// TabThumbnailCache's own doc comment). This is the only place a
    /// thumbnail is ever captured -- a tab that's never been deactivated
    /// this session (including a lazy-restored background tab whose
    /// CefBrowser was never created) simply has none yet, and the overview
    /// falls back to a favicon+title placeholder for it.
    private func captureThumbnail(for tab: Tab) {
        let hostView = tab.hostView
        guard hostView.bounds.width > 0, hostView.bounds.height > 0,
              let rep = hostView.bitmapImageRepForCachingDisplay(in: hostView.bounds) else { return }
        hostView.cacheDisplay(in: hostView.bounds, to: rep)
        let image = NSImage(size: hostView.bounds.size)
        image.addRepresentation(rep)
        thumbnailCache.setImage(image, for: tab.id)
    }

    /// TabOverviewController's read-only window into thumbnailCache.
    func thumbnailImage(forTabId tabId: UUID) -> NSImage? {
        thumbnailCache.image(for: tabId)
    }

    /// ⇧⌘\ / View > Tab Overview -- toggles this window's overview grid.
    @objc func showTabOverview(_ sender: Any?) {
        tabOverview.toggle()
    }

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let wasActive = index == activeTabIndex

        tabs[index].hostView.removeFromSuperview()
        thumbnailCache.removeImage(for: tabs[index].id)
        tabs[index].close()
        let closedTab = tabs.remove(at: index)
        // Posted before the tabs.isEmpty/window-closing early return below,
        // so the last tab's close is never silently skipped.
        TabLifecycleCenter.shared.post(.closed, tab: closedTab, in: self)

        if tabs.isEmpty {
            activeTabIndex = nil
            window?.close()
            return
        }

        let newActiveIndex: Int
        if wasActive {
            newActiveIndex = min(index, tabs.count - 1)
        } else if let current = activeTabIndex {
            newActiveIndex = current > index ? current - 1 : current
        } else {
            newActiveIndex = 0
        }

        tabStripView.reload(tabs: currentDisplayInfos, groups: currentGroupDisplayInfos, selectedIndex: newActiveIndex)

        if wasActive {
            activeTabIndex = nil
            activateTab(at: newActiveIndex, updateStrip: false)
        } else {
            activeTabIndex = newActiveIndex
        }
        // The tabs.isEmpty/window-closing early return above doesn't need
        // this: closing the window fires onWindowClosed, which already
        // schedules a save (see WindowManager.registerAndShow).
        WindowManager.shared.scheduleSessionSave()
    }

    /// Context menu's "Close Other Tabs": closes every unpinned tab except
    /// the one at `keepIndex` (which may itself be pinned or unpinned).
    /// Pinned tabs are never closed by this action -- matching Safari/
    /// Chrome's treatment of pins as surviving a bulk "close others."
    /// Iterates indices in reverse so removing tabs as we go never
    /// invalidates an index not yet visited.
    func closeOtherTabs(keeping keepIndex: Int) {
        guard tabs.indices.contains(keepIndex) else { return }
        let keepTab = tabs[keepIndex]
        for index in tabs.indices.reversed() {
            guard tabs[index] !== keepTab, !tabs[index].isPinned else { continue }
            closeTab(at: index)
        }
    }

    /// Pins the tab at `index`, moving it to the end of the pinned section
    /// (Safari's placement for a newly pinned tab) -- a no-op if already
    /// pinned or the index is out of range. Pinning always leaves any group
    /// first (see moveTab(at:toGroup:)'s doc comment on why pin and group
    /// are mutually exclusive).
    func pinTab(at index: Int) {
        guard tabs.indices.contains(index), !tabs[index].isPinned else { return }
        tabs[index].groupId = nil
        movePinState(at: index, toPinned: true)
    }

    /// Unpins the tab at `index`, moving it to the head of the unpinned
    /// section (explicitly requested: "unpinning returns it to the unpinned
    /// section head") -- a no-op if not pinned or the index is out of range.
    func unpinTab(at index: Int) {
        guard tabs.indices.contains(index), tabs[index].isPinned else { return }
        movePinState(at: index, toPinned: false)
    }

    /// Moves the tab at `index` into (or out of) the pinned section,
    /// preserving the [pinned][group sections][loose] ordering invariant the
    /// rest of this class relies on (⌘1-9/Ctrl+Tab cycling and every
    /// tabs[index]-based method here all just walk `tabs` in array order,
    /// with no separate "display order" to keep in sync). Both directions
    /// reduce to the same move: "insert right after however many pinned
    /// tabs remain" -- that's the end of the pinned section when pinning,
    /// and the head of everything-else when unpinning (a tab is never both
    /// pinned and grouped, so "everything else" from the unpinned side is
    /// unambiguous).
    private func movePinState(at index: Int, toPinned: Bool) {
        let activeTabObject = activeTab
        let tab = tabs.remove(at: index)
        tab.isPinned = toPinned
        let insertionIndex = tabs.filter { $0.isPinned }.count
        tabs.insert(tab, at: insertionIndex)
        reloadAfterReorder(activeTabObject: activeTabObject)
    }

    /// Drag-to-reorder's model change (browser-rhi.6): moves the tab at
    /// `index` so it ends up at `destination` in `tabs`. `destination` is the
    /// tab's position in the *final* array, so a rightward move needs no
    /// off-by-one adjustment at the call site.
    ///
    /// The [pinned][group sections][loose] ordering invariant is upheld by
    /// TabStripView refusing to drag a tab out of its own section, not
    /// re-derived here; a destination outside the tab's section would quietly
    /// break the invariant, so this deliberately isn't a general-purpose
    /// "move a tab anywhere" entry point (pin/group changes go through
    /// movePinState/moveTab(at:toGroup:), which do maintain it).
    func reorderTab(at index: Int, toIndex destination: Int) {
        guard tabs.indices.contains(index), tabs.indices.contains(destination), index != destination else {
            TabDragDiagnostics.record("modelMoveRejected", [
                "sourceIndex": index, "destinationIndex": destination, "tabCount": tabs.count
            ])
            return
        }
        let activeTabObject = activeTab
        let tab = tabs.remove(at: index)
        tabs.insert(tab, at: destination)
        TabDragDiagnostics.record("modelMoveApplied", [
            "sourceIndex": index, "destinationIndex": destination,
            "order": tabs.map { $0.displayTitle }
        ])
        reloadAfterReorder(activeTabObject: activeTabObject)
    }

    /// Common tail of every operation that removes-and-reinserts a tab
    /// elsewhere in `tabs` (movePinState, moveTab(at:toGroup:), ungroupAll):
    /// recomputes activeTabIndex by object identity (the move may have
    /// shifted it), does a full strip reload, and persists.
    private func reloadAfterReorder(activeTabObject: Tab?) {
        activeTabIndex = activeTabObject.flatMap { obj in tabs.firstIndex { $0 === obj } }
        tabStripView.reload(tabs: currentDisplayInfos, groups: currentGroupDisplayInfos, selectedIndex: activeTabIndex ?? 0)
        WindowManager.shared.scheduleSessionSave()
    }

    // MARK: - Tab groups (browser-rhi.1)

    /// Indices into `tabs`, in order, of every tab NOT hidden by a collapsed
    /// group -- every pinned/loose tab, plus every tab in an expanded group,
    /// but none in a collapsed one. ⌘1-9 (BrowserWindow.performKeyEquivalent,
    /// via selectVisibleTab(atPosition:)) and Ctrl+Tab cycling
    /// (selectNextTab/selectPreviousTab) both operate over this sequence --
    /// collapsed groups' tabs are skipped, not merely visually hidden.
    var visibleTabIndices: [Int] {
        tabs.indices.filter { index in
            guard let groupId = tabs[index].groupId else { return true }
            return !(tabGroups.first { $0.id == groupId }?.isCollapsed ?? false)
        }
    }

    /// ⌘1-9 -- called from BrowserWindow.performKeyEquivalent with a
    /// 0-indexed position among *visible* tabs (collapsed groups' tabs don't
    /// count), matching selectNextTab/selectPreviousTab's cycling sequence.
    func selectVisibleTab(atPosition position: Int) {
        let visible = visibleTabIndices
        guard visible.indices.contains(position) else { return }
        selectTab(at: visible[position])
    }

    /// Moves the tab at `index` to belong to `groupId` (nil ungroups it,
    /// landing in the loose section) -- the tab-groups analog of
    /// movePinState. Pinning and grouping are mutually exclusive (the
    /// ordering invariant is [pinned][group sections][loose], so a tab can't
    /// be in both), so joining a group always unpins first. A new member
    /// joins the end of its group's section (mirroring pinTab's "a new pin
    /// joins the end of its section"); leaving a group moves to the head of
    /// the loose section (mirroring unpinTab's "unpinning returns to the
    /// head of its section").
    func moveTab(at index: Int, toGroup groupId: UUID?) {
        guard tabs.indices.contains(index) else { return }
        let activeTabObject = activeTab
        let tab = tabs.remove(at: index)
        tab.isPinned = false
        tab.groupId = groupId

        guard let groupId, let groupPosition = tabGroups.firstIndex(where: { $0.id == groupId }) else {
            // Ungrouping (or a groupId that's vanished, defensively treated
            // the same way rather than silently dropping the tab): head of
            // the loose section, right after every pinned tab and every
            // still-grouped tab.
            tab.groupId = nil
            let insertionIndex = tabs.filter { $0.isPinned || $0.groupId != nil }.count
            tabs.insert(tab, at: insertionIndex)
            reloadAfterReorder(activeTabObject: activeTabObject)
            return
        }

        // End of the target group's section: every pinned tab, plus every
        // tab in a group at or before this one in tabGroups order, plus
        // this group's own remaining members (the tab being moved was
        // already removed above, so this count excludes it).
        let precedingGroupIds = Set(tabGroups[..<groupPosition].map { $0.id })
        let precedingCount = tabs.filter { $0.isPinned || ($0.groupId.map(precedingGroupIds.contains) ?? false) }.count
        let thisGroupCount = tabs.filter { $0.groupId == groupId }.count
        tabs.insert(tab, at: precedingCount + thisGroupCount)
        reloadAfterReorder(activeTabObject: activeTabObject)
    }

    /// Tab context menu > "Move to Group > New Group…": prompts for a
    /// name/color, creates the group at the end of tabGroups (its section
    /// lands after every existing group, before loose tabs), then moves the
    /// tab into it.
    func moveTabToNewGroup(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard let result = TabGroupPrompt.run(currentName: "", currentColorHex: nextUnusedGroupColor(), isNew: true) else { return }
        let group = TabGroup(name: result.name, colorHex: result.colorHex)
        tabGroups.append(group)
        moveTab(at: index, toGroup: group.id)
    }

    /// Mirrors ProfileManager.nextUnusedColor(), scoped to this window's own
    /// groups rather than the global profile list.
    private func nextUnusedGroupColor() -> String {
        let used = Set(tabGroups.map { $0.colorHex })
        return ProfileColorPalette.hexValues.first { !used.contains($0) }
            ?? ProfileColorPalette.hexValues[tabGroups.count % ProfileColorPalette.hexValues.count]
    }

    /// Group header click: toggle collapsed/expanded. If the active tab is a
    /// member of the group being collapsed, it would otherwise become
    /// selected-but-invisible -- reassign to the nearest still-visible tab
    /// instead.
    func toggleGroupCollapse(groupId: UUID) {
        guard let position = tabGroups.firstIndex(where: { $0.id == groupId }) else { return }
        tabGroups[position].isCollapsed.toggle()

        if tabGroups[position].isCollapsed, let active = activeTabIndex, tabs.indices.contains(active), tabs[active].groupId == groupId {
            let visible = visibleTabIndices
            let fallback = visible.first(where: { $0 > active }) ?? visible.last(where: { $0 < active }) ?? visible.first
            if let fallback {
                selectTab(at: fallback)
            }
        }

        tabStripView.reload(tabs: currentDisplayInfos, groups: currentGroupDisplayInfos, selectedIndex: activeTabIndex ?? 0)
        WindowManager.shared.scheduleSessionSave()
    }

    /// Group header context menu > "Rename" or "Change Color" -- both open
    /// the same combined name+color prompt (see TabGroupPrompt, mirroring
    /// NewProfilePrompt's create/edit reuse), since it already lets you
    /// change either from one dialog.
    func renameOrRecolorGroup(groupId: UUID) {
        guard let position = tabGroups.firstIndex(where: { $0.id == groupId }) else { return }
        guard let result = TabGroupPrompt.run(currentName: tabGroups[position].name, currentColorHex: tabGroups[position].colorHex, isNew: false) else { return }
        tabGroups[position].name = result.name
        tabGroups[position].colorHex = result.colorHex
        tabStripView.reload(tabs: currentDisplayInfos, groups: currentGroupDisplayInfos, selectedIndex: activeTabIndex ?? 0)
        WindowManager.shared.scheduleSessionSave()
    }

    /// Group header context menu > "Ungroup All": every member tab becomes
    /// loose (unlabeled), relocated as a contiguous block to the head of the
    /// loose section (immediately after every remaining group) -- keeps the
    /// [pinned][groups][loose] invariant intact rather than leaving a gap
    /// where this group's section used to be. The group definition itself is
    /// removed, since an empty group has nothing left to render.
    func ungroupAll(groupId: UUID) {
        guard let groupPosition = tabGroups.firstIndex(where: { $0.id == groupId }) else { return }
        let activeTabObject = activeTab
        let memberTabs = tabs.filter { $0.groupId == groupId }
        tabGroups.remove(at: groupPosition)

        guard !memberTabs.isEmpty else {
            reloadAfterReorder(activeTabObject: activeTabObject)
            return
        }
        tabs.removeAll { $0.groupId == groupId }
        for tab in memberTabs { tab.groupId = nil }
        let insertionIndex = tabs.filter { $0.isPinned || $0.groupId != nil }.count
        tabs.insert(contentsOf: memberTabs, at: insertionIndex)
        reloadAfterReorder(activeTabObject: activeTabObject)
    }

    /// Group header context menu > "Close Group": closes every tab currently
    /// in the group, confirming first if there are more than 3 (this can't
    /// be undone). The group definition is dropped once its tabs are gone.
    /// Reuses closeTab(at:) per tab (same window-closes-when-empty handling
    /// as Close Other Tabs), iterating in reverse so removing tabs mid-loop
    /// never invalidates an index not yet visited.
    func closeGroup(groupId: UUID) {
        let memberIndices = tabs.indices.filter { tabs[$0].groupId == groupId }
        guard !memberIndices.isEmpty else {
            tabGroups.removeAll { $0.id == groupId }
            return
        }
        if memberIndices.count > 3 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Close \(memberIndices.count) Tabs?"
            alert.informativeText = "This will close every tab in this group. This can't be undone."
            alert.addButton(withTitle: "Close Tabs")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for index in memberIndices.reversed() {
            closeTab(at: index)
        }
        tabGroups.removeAll { $0.id == groupId }
        tabStripView.reload(tabs: currentDisplayInfos, groups: currentGroupDisplayInfos, selectedIndex: activeTabIndex ?? 0)
    }

    private func refreshToolbar(for tab: Tab) {
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        // Domain-only while the pill is collapsed/unfocused (browser-qpy);
        // the full URL only while actually being edited -- see
        // setOmniboxFocused(_:animated:), which is what actually flips
        // isOmniboxFocused.
        if omniboxField.currentEditor() == nil {
            omniboxField.stringValue = isOmniboxFocused ? tab.urlString : Self.collapsedOmniboxDisplay(for: tab)
        }
        updateChromeTint(for: tab)
        refreshContentBlockerButton(for: tab)
    }

    /// Drives the thin loading-progress bar below the omnibox pill
    /// (browser-7z5) from Tab.loadingProgress/isLoading. Safari-style
    /// completion: rather than instantly disappearing at 100%, the bar
    /// briefly shows a full fill before fading out, so a very fast
    /// navigation doesn't look like the bar never appeared at all.
    private func updateLoadingProgressBar(for tab: Tab) {
        let trackWidth = omniboxContainerView.frame.width
        if tab.isLoading {
            loadingProgressCompletionWorkItem?.cancel()
            loadingProgressView.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                loadingProgressView.animator().alphaValue = 1
                loadingProgressView.animator().frame.size.width = max(4, trackWidth * CGFloat(tab.loadingProgress))
            }
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                loadingProgressView.animator().frame.size.width = trackWidth
            }
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.activeTab === tab, !tab.isLoading else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    self.loadingProgressView.animator().alphaValue = 0
                }
            }
            loadingProgressCompletionWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
        }
    }

    /// browser-12m.5.1.1 -- hidden entirely on a page with nothing blocked
    /// yet (matches Safari's own convention: no icon shown until there's
    /// something to say), otherwise a shield glyph + the blocked count.
    private func refreshContentBlockerButton(for tab: Tab) {
        let count = tab.blockedRequestCount
        guard count > 0 else {
            contentBlockerButton.isHidden = true
            layoutOmniboxInnerContent()
            return
        }
        contentBlockerButton.isHidden = false
        contentBlockerButton.image = NSImage(systemSymbolName: "shield.fill", accessibilityDescription: "Trackers blocked")
        contentBlockerButton.title = " \(count)"
        contentBlockerButton.sizeToFit()
        layoutOmniboxInnerContent()
    }

    /// View > (click) the content blocker shield -- browser-12m.5.1.1.
    @objc private func toggleContentBlockerPopover(_ sender: Any?) {
        guard let tab = activeTab, let host = URL(string: tab.urlString)?.host else { return }
        contentBlockerPopover.toggle(
            anchorView: contentBlockerButton, profileId: profile.id, host: host,
            blockedCount: tab.blockedRequestCount, isPrivate: isPrivate
        )
    }

    /// Blends this window's profile accent (always, as a subtle baseline)
    /// and the active tab's site theme color (browser-rhi.5, when present
    /// -- more prominent, since it's more specific/timely than the
    /// per-window profile identity) into the shared glass background.
    /// Always re-evaluated against whichever tab is *currently* active, so
    /// it updates both when that tab's own color changes (navigation) and
    /// when a different tab becomes active (tab switch) -- refreshToolbar(
    /// for:) is already the one call site both of those already go through.
    /// A private window shows no profile-accent baseline (no real profile
    /// to accent), just the active tab's theme color when present.
    ///
    /// This tints an already-translucent glass surface, not a solid
    /// background -- unlike NSColor.tinted(withThemeColorHex:) (used by
    /// TabButtonView, which blends against one specific solid base color
    /// and rechecks WCAG contrast), so it doesn't reuse that helper; both
    /// alpha values below are deliberately conservative enough to stay
    /// legible over vibrancy without needing a fresh contrast check for
    /// every possible glass/vibrancy combination.
    private func updateChromeTint(for tab: Tab) {
        let themeColor = tab.themeColorHex.flatMap { NSColor(hex: $0) }
        let profileColor = isPrivate ? nil : (NSColor(hex: profile.colorHex) ?? .controlAccentColor)
        guard let tintColor = themeColor ?? profileColor else {
            chromeBackground.tintColor = nil
            return
        }
        let alpha: CGFloat = themeColor != nil ? 0.16 : 0.05
        chromeBackground.tintColor = tintColor.withAlphaComponent(alpha)
    }

    private func updateWindowTitle(for tab: Tab) {
        // displayTitle, not title (browser-7z5) -- same "show the target
        // host, not a stale title" reasoning as the tab strip; otherwise
        // Mission Control/Cmd-Tab previews would show the old page's title
        // for however long the new one takes to load, same "looks broken"
        // symptom Brady reported for the tab strip.
        window?.title = isPrivate ? "\(tab.displayTitle) — Private Browsing" : "\(tab.displayTitle) — \(profile.name)"
    }

    // MARK: - TabDelegate

    func tabDidChangeDisplayState(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        // displayTitle, not title (browser-7z5) -- shows the target host as
        // a placeholder while loading and before a real title has arrived
        // for the current navigation, instead of the previous page's now-
        // stale title (see Tab.displayTitle's own doc comment).
        tabStripView.updateTitle(at: index, title: tab.displayTitle)
        tabStripView.updateFavicon(at: index, image: tab.faviconImage)
        tabStripView.updateThemeColor(at: index, hex: tab.themeColorHex)
        tabStripView.updateAudioState(at: index, isMuted: tab.isMuted, isAudible: tab.isAudible)
        tabStripView.updateLoadingState(at: index, isLoading: tab.isLoading)
        if index == activeTabIndex {
            refreshToolbar(for: tab)
            updateWindowTitle(for: tab)
            updateLoadingProgressBar(for: tab)
        }
        // See Tab.needsInitialOmniboxFocus: CEF's own view reliably takes
        // first responder for itself shortly after the tab's initial load
        // settles, winning the race against addTab's earlier
        // makeFirstResponder(omniboxField) call. Re-assert once, right when
        // that settling happens, so the omnibox actually ends up focused --
        // deferred a run-loop turn for the same reason as addTab's own call
        // (the selection silently doesn't stick when done synchronously
        // here, same as there).
        if tab.needsInitialOmniboxFocus, !tab.isLoading, tab === activeTab {
            tab.needsInitialOmniboxFocus = false
            DispatchQueue.main.async { [weak self] in
                self?.focusOmnibox(nil)
            }
        }
    }

    // MARK: - TabStripViewDelegate

    func tabStripView(_ tabStripView: TabStripView, didSelectTabAt index: Int) {
        selectTab(at: index)
    }

    func tabStripView(_ tabStripView: TabStripView, didCloseTabAt index: Int) {
        closeTab(at: index)
    }

    func tabStripViewDidClickNewTab(_ tabStripView: TabStripView) {
        newTab(nil)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestPinToggleAt index: Int) {
        guard tabs.indices.contains(index) else { return }
        if tabs[index].isPinned {
            unpinTab(at: index)
        } else {
            pinTab(at: index)
        }
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestMuteToggleAt index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].toggleMuted()
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestCloseOthersAt index: Int) {
        closeOtherTabs(keeping: index)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestMoveToGroupAt index: Int, groupId: UUID) {
        moveTab(at: index, toGroup: groupId)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestMoveToNewGroupAt index: Int) {
        moveTabToNewGroup(at: index)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestRemoveFromGroupAt index: Int) {
        moveTab(at: index, toGroup: nil)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestToggleCollapseForGroup groupId: UUID) {
        toggleGroupCollapse(groupId: groupId)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestRenameForGroup groupId: UUID) {
        renameOrRecolorGroup(groupId: groupId)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestChangeColorForGroup groupId: UUID) {
        renameOrRecolorGroup(groupId: groupId)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestUngroupAllForGroup groupId: UUID) {
        ungroupAll(groupId: groupId)
    }

    func tabStripView(_ tabStripView: TabStripView, didRequestCloseGroup groupId: UUID) {
        closeGroup(groupId: groupId)
    }

    func tabStripView(_ tabStripView: TabStripView, didMoveTabAt sourceIndex: Int, toIndex destinationIndex: Int) {
        reorderTab(at: sourceIndex, toIndex: destinationIndex)
    }

    // MARK: - Menu / keyboard actions (reached via the responder chain --
    // NSWindowController is automatically next-responder after its window).

    @objc func newTab(_ sender: Any?) {
        // Blank page + focused, selected address bar is the standard new-tab
        // UX -- loading a real page here would fight with the omnibox-focus
        // flow (the user is about to type over it anyway).
        addTab(url: "about:blank", makeActive: true)
    }

    /// ⌘W / File > Close Tab -- both this menu item's keyboard shortcut and
    /// an explicit click share this one selector, so a pinned active tab
    /// blocks both the same way: a brief shake instead of closing. This is
    /// deliberately narrower than closeTab(at:) itself -- the tab strip's
    /// context menu "Close Tab" calls that directly (see
    /// tabStripView(_:didCloseTabAt:)), and does close a pinned tab, since
    /// that's an explicit, deliberate action rather than a habitual ⌘W.
    @objc func closeTab(_ sender: Any?) {
        guard let index = activeTabIndex else { return }
        guard !tabs[index].isPinned else {
            tabStripView.shakeTab(at: index)
            return
        }
        closeTab(at: index)
    }

    /// Ctrl+Tab -- cycles over *visible* tabs only (browser-rhi.1: a
    /// collapsed tab group's members are skipped, not merely hidden; see
    /// visibleTabIndices), matching ⌘1-9's same "visible tabs as one
    /// sequence" rule (selectVisibleTab(atPosition:)).
    @objc func selectNextTab(_ sender: Any?) {
        let visible = visibleTabIndices
        guard let current = activeTabIndex, let position = visible.firstIndex(of: current), !visible.isEmpty else { return }
        selectTab(at: visible[(position + 1) % visible.count])
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        let visible = visibleTabIndices
        guard let current = activeTabIndex, let position = visible.firstIndex(of: current), !visible.isEmpty else { return }
        selectTab(at: visible[(position - 1 + visible.count) % visible.count])
    }

    /// ⌥⌘P / Window > Pin Tab -- pins or unpins the active tab. Menu item
    /// title toggles in validateMenuItem(_:) below.
    @objc func togglePinActiveTab(_ sender: Any?) {
        guard let index = activeTabIndex else { return }
        if tabs[index].isPinned {
            unpinTab(at: index)
        } else {
            pinTab(at: index)
        }
    }

    @objc func goBackAction(_ sender: Any?) {
        activeTab?.goBack()
    }

    @objc func goForwardAction(_ sender: Any?) {
        activeTab?.goForward()
    }

    @objc func reloadPage(_ sender: Any?) {
        activeTab?.reload()
    }

    /// ⌘+ (and ⌘=, see MainMenuBuilder.appendZoomItems) -- browser-5kq.15.
    /// Applied to the active tab, though the effect is not confined to it:
    /// CEF scopes zoom per host per profile, so sibling tabs on the same host
    /// follow, exactly as in Chrome -- see Tab.zoomFactor. Clamping lives in
    /// PageZoom's ladder, so holding the shortcut down can't run away past
    /// 500%/25%.
    @objc func zoomIn(_ sender: Any?) {
        activeTab?.zoomIn()
    }

    @objc func zoomOut(_ sender: Any?) {
        activeTab?.zoomOut()
    }

    /// ⌘0 -- back to exactly 100%.
    @objc func actualSize(_ sender: Any?) {
        activeTab?.resetZoom()
    }

    @objc func focusOmnibox(_ sender: Any?) {
        // Put the full, editable URL in before taking focus: once the field
        // editor exists, controlTextDidBeginEditing deliberately leaves the
        // text alone so a keystroke-initiated edit isn't clobbered, so this
        // is the only place the expanded form gets written.
        if let tab = activeTab {
            omniboxField.stringValue = tab.urlString
        }
        window?.makeFirstResponder(omniboxField)
        omniboxField.currentEditor()?.selectAll(nil)
    }

    /// ⌘⇧C -- the headline feature: copy the active tab's current URL.
    @objc func copyCurrentURL(_ sender: Any?) {
        guard let tab = activeTab else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tab.urlString, forType: .string)
        showCopiedFeedback(for: tab)
    }

    /// Transient "Copied to Clipboard" swap in the collapsed omnibox pill
    /// (browser-0y1, Brady's ask -- ⌘⇧C gave no visible confirmation
    /// before). Skipped entirely while the field is focused/being edited
    /// so this can never clobber an in-progress edit -- the copy above
    /// still happens either way, just silently in that case. Reverts to
    /// whatever collapsedOmniboxDisplay(for:) says *at the time the timer
    /// fires* (not a captured value), so it always restores to the
    /// current display-mode preference and the tab that's active by
    /// then -- correct even if the preference or active tab changed in the
    /// meantime (e.g. a tab switch's own refreshToolbar(for:) already
    /// overwrote this, in which case this just harmlessly reapplies the
    /// same value). Rapid repeat presses cancel and restart the same
    /// timer rather than stacking reverts.
    private func showCopiedFeedback(for tab: Tab) {
        guard !isOmniboxFocused else { return }
        copiedFeedbackWorkItem?.cancel()
        omniboxField.stringValue = "Copied to Clipboard"
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let currentTab = self.activeTab, !self.isOmniboxFocused else { return }
            self.omniboxField.stringValue = Self.collapsedOmniboxDisplay(for: currentTab)
        }
        copiedFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: workItem)
    }

    /// ⌘/ (always) or bare "?" (when native chrome has focus, see
    /// isNativeChromeFocused) -- shows/hides the keyboard shortcuts overlay.
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        ShortcutsOverlayController.shared.toggle(relativeTo: window)
    }

    /// Whether the key window's first responder is native chrome -- not the
    /// omnibox mid-edit, and not inside the active tab's CEF content view.
    /// Gates the bare "?" shortcuts-overlay trigger in
    /// ShortcutsOverlayController: typing "?" into the omnibox or a focused
    /// element on the web page must just type the character. CEF's content
    /// view doesn't expose page-level focus state at this layer, so "isn't
    /// inside the tab's hostView" is the closest dependable proxy for "isn't
    /// typing into the page."
    var isNativeChromeFocused: Bool {
        guard let firstResponder = window?.firstResponder else { return true }
        if let editor = omniboxField.currentEditor(), firstResponder === editor {
            return false
        }
        if let tab = activeTab, let responderView = firstResponder as? NSView,
           responderView.isDescendant(of: tab.hostView) {
            return false
        }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBackAction(_:)):
            return activeTab?.canGoBack ?? false
        case #selector(goForwardAction(_:)):
            return activeTab?.canGoForward ?? false
        case #selector(togglePinActiveTab(_:)):
            menuItem.title = (activeTab?.isPinned ?? false) ? "Unpin Tab" : "Pin Tab"
            return activeTab != nil
        default:
            return true
        }
    }

    // MARK: - Omnibox

    @objc private func omniboxSubmitted() {
        let text = omniboxField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        commitOmniboxNavigation(to: Self.resolveOmniboxSubmission(text))
    }

    /// Shared by omniboxSubmitted (raw typed text, already resolved) and
    /// both autocomplete confirmation paths (Enter on a highlighted
    /// suggestion, or clicking one directly) -- a suggestion's URL is already
    /// absolute, so resolveOmniboxSubmission is only ever applied once, here
    /// or by the caller, never both.
    private func commitOmniboxNavigation(to resolved: String) {
        guard let tab = activeTab else { return }
        autocomplete.dismiss()
        // End editing (and only then set the resolved text) before touching
        // CEF: ending the field's edit session re-syncs stringValue from the
        // (stale, pre-resolution) field editor buffer, which would otherwise
        // clobber a value set while still editing.
        window?.makeFirstResponder(nil)
        omniboxField.stringValue = resolved
        // Deferred a run-loop turn because Return's key-event dispatch runs
        // this method synchronously from deep inside AppKit's Text Services
        // Manager machinery -- calling into CEF from that exact stack is its
        // own reentrancy hazard, on top of (and independent from) the one
        // BRWMessagePump.mm's OnScheduleMessagePumpWork now guards against
        // for every CEF-originated call, not just this one. Belt and braces.
        DispatchQueue.main.async {
            tab.load(url: resolved)
        }
    }

    /// Enter behavior per docs/plans/2026-07-27-browser-plan.md M1 scope: add
    /// https:// if the scheme is missing; if the input doesn't look like a
    /// domain (no dot, or contains a space) treat it as a DuckDuckGo search.
    static func resolveOmniboxSubmission(_ text: String) -> String {
        if text.contains("://") {
            return text
        }
        let looksLikeDomain = text.contains(".") && !text.contains(" ")
        if looksLikeDomain {
            return "https://" + text
        }
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return "https://duckduckgo.com/?q=\(encoded)"
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            return previewAutocompleteSelection(delta: 1)
        case #selector(NSResponder.moveUp(_:)):
            return previewAutocompleteSelection(delta: -1)
        case #selector(NSResponder.insertNewline(_:)):
            return commitHighlightedAutocompleteSuggestion()
        case #selector(NSResponder.cancelOperation(_:)):
            // Standard browser Escape behavior: the first press just closes
            // an open suggestions dropdown; only a second press (dropdown
            // already closed) reverts the omnibox text and blurs it.
            if autocomplete.isVisible {
                autocomplete.dismiss()
                return true
            }
            if let tab = activeTab {
                omniboxField.stringValue = tab.urlString
            }
            window?.makeFirstResponder(nil)
            return true
        default:
            return false
        }
    }

    /// Arrow-key-through-suggestions: highlights the next/previous row and
    /// previews its URL in the omnibox text without navigating -- matches
    /// standard browser omnibox behavior. Returns false (letting AppKit's
    /// default handling run) when the dropdown isn't showing, so arrow keys
    /// behave normally the rest of the time.
    private func previewAutocompleteSelection(delta: Int) -> Bool {
        guard autocomplete.isVisible, let suggestion = autocomplete.moveSelection(by: delta) else { return false }
        omniboxField.stringValue = suggestion.url
        return true
    }

    private func commitHighlightedAutocompleteSuggestion() -> Bool {
        guard autocomplete.isVisible, let suggestion = autocomplete.highlightedSuggestion else { return false }
        commitOmniboxNavigation(to: suggestion.url)
        return true
    }

    /// NSTextFieldDelegate -- queries HistoryStore on every keystroke and
    /// shows/updates/hides the autocomplete dropdown. This is the omnibox
    /// autocomplete feature's live-as-you-type entry point.
    func controlTextDidChange(_ obj: Notification) {
        guard let window else { return }
        let history = ProfileDataStoreManager.shared.stores(for: profile).history
        autocomplete.update(query: omniboxField.stringValue, history: history, below: omniboxField, in: window)
    }

    /// NSTextFieldDelegate -- fires when the field editor actually attaches
    /// (a click into the field, or ⌘L's makeFirstResponder call in
    /// focusOmnibox(_:) below) -- expands the omnibox pill (browser-qpy).
    func controlTextDidBeginEditing(_ obj: Notification) {
        // Expand the pill only -- never rewrite the text here. This fires on
        // the user's first keystroke as well as on a click, and replacing
        // stringValue mid-edit discards what they just typed (see
        // setOmniboxFocused's own note).
        setOmniboxFocused(true, animated: true, updatesText: false)
    }

    /// NSTextFieldDelegate -- fires when the field editor resigns (Escape's
    /// or commitOmniboxNavigation's makeFirstResponder(nil) calls, or a
    /// click elsewhere) -- collapses the pill back to domain-only.
    func controlTextDidEndEditing(_ obj: Notification) {
        // Collapse the pill, but do NOT rewrite the text synchronously:
        // AppKit ends the editing session *before* sending the field's
        // action, so replacing stringValue here would hand omniboxSubmitted
        // the current page's URL instead of what the user typed -- Enter
        // would then "navigate" straight back to the page already open.
        //
        // The restore is deferred a run-loop turn instead, by which point
        // either omniboxSubmitted has run (and commitOmniboxNavigation has
        // set the resolved URL, so refreshing to the tab's own display is
        // correct) or the edit was simply abandoned (a click elsewhere),
        // where restoring the collapsed display is exactly what's wanted.
        setOmniboxFocused(false, animated: true, updatesText: false)
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isOmniboxFocused, let tab = self.activeTab else { return }
            self.omniboxField.stringValue = Self.collapsedOmniboxDisplay(for: tab)
        }
    }

    // MARK: - Furniture: history / bookmarks / downloads

    /// ⌘D -- opens the Add Bookmark popover (browser-5kq.7): editable name
    /// (prefilled from the page's title), a folder picker defaulting to
    /// Favorites, Add/Cancel. Superseded the old silent-top-level-file
    /// behavior (see docs/ai-tasks/m3-furniture-notes.md's scope cut) -- this
    /// is the fix for "no discoverable path from a page you like to it
    /// showing up in the start page's Favorites grid," since the old
    /// behavior could never file into Favorites at all without a trip
    /// through the Bookmarks manager afterward.
    @objc func addBookmark(_ sender: Any?) {
        guard let tab = activeTab else { return }
        let bookmarks = ProfileDataStoreManager.shared.stores(for: profile).bookmarks
        addBookmarkPrompt.show(pageTitle: tab.title, bookmarks: bookmarks, anchorView: omniboxField) { name, folderId in
            try? bookmarks.addBookmark(title: name, url: tab.urlString, parentId: folderId)
        }
    }

    /// "Add to Favourites" in the Bookmarks menu (browser-5kq.7) -- the
    /// no-popover, one-click discoverable route team-lead asked for
    /// alongside ⌘D's editable popover above: files the active tab straight
    /// into Favorites with its current title, no picker, no decision to
    /// make. Silently no-ops with no active tab (matches addBookmark(_:)'s
    /// own guard) rather than asserting -- this is reachable from a menu
    /// item with no target-validation wired up yet for "is there an active
    /// tab," same as every other furniture action in this section.
    @objc func addActiveTabToFavorites(_ sender: Any?) {
        guard let tab = activeTab else { return }
        let bookmarks = ProfileDataStoreManager.shared.stores(for: profile).bookmarks
        guard let favoritesId = FavoritesFolder.id(in: bookmarks) else { return }
        try? bookmarks.addBookmark(title: tab.title, url: tab.urlString, parentId: favoritesId)
    }

    /// ⌘Y -- "Show All History…"
    @objc func showHistory(_ sender: Any?) {
        HistoryWindowManager.shared.show(for: profile)
    }

    @objc func showBookmarksManager(_ sender: Any?) {
        BookmarksWindowManager.shared.show(for: profile)
    }

    /// ⌘⇧J -- matches Chrome's downloads shortcut.
    @objc func showDownloads(_ sender: Any?) {
        DownloadsWindowManager.shared.show(for: profile)
    }

    /// ⌥⌘I -- matches Chrome/Safari's DevTools shortcut. "JavaScript
    /// Console" in the Developer menu aliases this same action for now (see
    /// docs/ai-tasks/m3-furniture-notes.md's DevTools section) -- CEF's
    /// ShowDevTools always opens the full inspector, there's no separate
    /// "console-only" entry point to route to instead.
    @objc func showDevTools(_ sender: Any?) {
        activeTab?.showDevTools()
    }

    /// Both of these exist purely to republish a Tab-level signal as a
    /// TabLifecycleEvent (browser-g6d) -- the window controller itself has
    /// nothing to do with either. They live on TabDelegate rather than being
    /// posted from Tab directly because a lifecycle event carries its owning
    /// BrowserWindowController, which the Tab doesn't know.
    func tab(_ tab: Tab, didChangeURLTo url: String) {
        TabLifecycleCenter.shared.post(.navigated, tab: tab, in: self)
    }

    func tabDidFinishLoading(_ tab: Tab) {
        TabLifecycleCenter.shared.post(.finishedLoading, tab: tab, in: self)
    }

    // MARK: - TabDelegate (furniture)

    func tab(_ tab: Tab, didCommitNavigationTo url: String) {
        // Private Browsing (browser-12m.1): never touches HistoryStore, and
        // deliberately doesn't even reach WindowManager.scheduleSessionSave --
        // this window is excluded from every session snapshot outright (see
        // WindowManager.currentSnapshot()), so there'd be nothing useful for
        // that save to persist about it anyway.
        guard !isPrivate else { return }
        let history = ProfileDataStoreManager.shared.stores(for: profile).history
        try? history.recordVisit(url: url, title: tab.title)
        if let appDelegate = NSApp.delegate as? AppDelegate, tab === activeTab {
            appDelegate.mainMenuBuilder.rebuildRecentHistory(for: profile)
        }
        WindowManager.shared.scheduleSessionSave()
    }

    func tab(_ tab: Tab, didBeginDownload info: TabDownloadStart) {
        // Private Browsing: the file still lands on disk (macOS gives no way
        // around that -- the user asked to save/open something real), but
        // it's never recorded in DownloadStore. See docs/plans's Private
        // Browsing notes for this being an accepted, documented limitation
        // shared with every mainstream browser's incognito mode.
        guard !isPrivate else { return }
        DownloadCoordinator.shared.beginDownload(profile: profile, info: info)
    }

    func tab(_ tab: Tab, didUpdateDownload info: TabDownloadUpdate) {
        guard !isPrivate else { return }
        DownloadCoordinator.shared.updateDownload(profile: profile, info: info)
    }

    /// A page wants camera/microphone/location/notification permission --
    /// see EngineTabDelegate.engineTabDidRequestPermission for the full
    /// contract. Checks PermissionStore for a remembered per-origin decision
    /// first; only shows the Safari-style prompt popover if none exists yet.
    func tab(_ tab: Tab, didRequestPermission kinds: EnginePermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void) {
        // Private Browsing: no PermissionStore lookup or write at all -- not
        // just "don't persist this decision" but "don't even remember it for
        // the rest of this window's life," matching every mainstream
        // browser's incognito behavior (a site re-prompts every time in a
        // private window, even within the same window/session).
        let store = isPrivate ? nil : PermissionStoreManager.shared.store(for: profile)
        if let store, let remembered = store.decision(for: requestingOrigin, kinds: kinds) {
            decision(remembered)
            return
        }

        // No remembered decision, so answering means showing UI -- only
        // possible for the tab that's actually visible right now. A
        // background tab's undecided request just denies immediately rather
        // than queuing until it becomes active. See
        // docs/ai-tasks/permissions-notes.md for why this is a documented v1
        // limitation rather than something more elaborate: media/
        // geolocation/notification requests overwhelmingly fire from a user
        // gesture on the tab that's already visible in practice.
        guard tab === activeTab else {
            decision(false)
            return
        }

        pendingPermissionRequest = (tab, promptId)
        permissionPrompt.show(kinds: kinds, origin: requestingOrigin, anchorView: omniboxField) { [weak self] allow in
            self?.pendingPermissionRequest = nil
            store?.setDecision(allow, for: requestingOrigin, kinds: kinds)
            decision(allow)
        }
    }

    func tab(_ tab: Tab, didDismissPermissionRequestWithId promptId: UInt64) {
        guard pendingPermissionRequest?.promptId == promptId else { return }
        pendingPermissionRequest = nil
        // CEF-initiated: its own underlying callback may already be invalid,
        // so this only tears down the UI, never answers the request -- see
        // PermissionPromptController.dismiss(invokingDecision:)'s doc comment.
        permissionPrompt.dismiss(invokingDecision: false)
    }

    /// A target="_blank" link or window.open() call this tab's page made,
    /// translated by Tab.engineTabDidRequestNewTab (see that method for the
    /// Cmd/Cmd+Shift/Shift modifier-key overrides) into "open as a new tab
    /// in this window." Lands immediately after the opener -- see
    /// openTabForLinkClick's own doc comment for the pinned/grouped-section
    /// fallback.
    func tab(_ tab: Tab, didRequestNewTabForURL url: String, foreground: Bool) {
        guard let openerIndex = tabs.firstIndex(where: { $0 === tab }) else {
            addTab(url: url, makeActive: foreground)
            return
        }
        openTabForLinkClick(url: url, afterIndex: openerIndex, foreground: foreground)
    }

    /// Same trigger as above, resolved to "open as a genuine new native
    /// window" instead -- always via this app's own window-creation code
    /// (WindowManager), never CEF's raw default popup window, which
    /// wouldn't be Swift-owned (no toolbar/tab strip/session-restore/quit-
    /// sequencing integration).
    func tab(_ tab: Tab, didRequestNewWindowForURL url: String) {
        WindowManager.shared.openNewWindow(profile: profile, initialURL: url, isPrivate: isPrivate)
    }

    private func dismissPermissionPromptIfShowing() {
        guard pendingPermissionRequest != nil else { return }
        pendingPermissionRequest = nil
        permissionPrompt.dismiss(invokingDecision: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        autocomplete.dismiss()
        dismissPermissionPromptIfShowing()
        tabOverview.dismiss()
        let closedTabs = tabs
        for tab in tabs {
            tab.close()
        }
        tabs.removeAll()
        for tab in closedTabs {
            TabLifecycleCenter.shared.post(.closed, tab: tab, in: self)
        }
        onWindowClosed?()
    }

    /// Window frame changes are part of the persisted session (see
    /// WindowManager.scheduleSessionSave) -- debounced, so dragging/resizing
    /// doesn't hammer disk on every intermediate frame.
    func windowDidMove(_ notification: Notification) {
        WindowManager.shared.scheduleSessionSave()
    }

    func windowDidResize(_ notification: Notification) {
        WindowManager.shared.scheduleSessionSave()
        // The omnibox pill isn't autoresizing-mask-stretched (see
        // omniboxFrame()'s explicit centered-width calculation, which
        // depends on the current toolbar width) -- reposition it live as
        // the window is dragged, same as any other manually-framed chrome
        // would need to on a resize.
        layoutOmniboxContainer()
    }
}
