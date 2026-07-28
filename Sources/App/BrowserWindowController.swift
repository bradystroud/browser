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
    private let omniboxField = NSTextField()
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
    /// True while the omnibox field is actually being edited (see
    /// controlTextDidBeginEditing/controlTextDidEndEditing below) -- expands
    /// the pill to show the full editable URL; false shows a narrow,
    /// domain-only pill (see Self.domainOnlyDisplay(for:)).
    private var isOmniboxFocused = false
    private static let omniboxPillHeight: CGFloat = 30
    private static let omniboxCollapsedWidth: CGFloat = 280
    /// Minimum breathing room between the expanded pill and whatever sits
    /// on either side of it (back/forward on the left, the private-browsing
    /// pill if any on the right).
    private static let omniboxHorizontalMargin: CGFloat = 16
    /// A simple "Private" pill -- the whole visual distinction Private
    /// Browsing gets for now (browser-12m.1). nil (never created) for a
    /// normal window. The profile-dot indicator this used to sit next to
    /// is gone (browser-qpy point 5: the profile accent is now a glass
    /// tint, not a solid dot -- see updateChromeTint(for:)), so this is
    /// now anchored directly off the toolbar's trailing edge instead.
    private let privateLabel: NSTextField?
    private let contentContainerView = NSView()
    private let autocomplete = OmniboxAutocompleteController()
    private let permissionPrompt = PermissionPromptController()
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
        } else {
            self.privateLabel = nil
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
                title: $0.title, favicon: $0.faviconImage, isPinned: $0.isPinned,
                groupId: $0.groupId, themeColorHex: $0.themeColorHex)
        }
    }

    private var currentGroupDisplayInfos: [TabStripView.GroupDisplayInfo] {
        tabGroups.map { TabStripView.GroupDisplayInfo(id: $0.id, name: $0.name, colorHex: $0.colorHex, isCollapsed: $0.isCollapsed) }
    }

    // MARK: - View setup

    /// Space reserved at the tab strip's leading edge for the traffic-light
    /// buttons, which float over this area now that the titlebar is hidden
    /// (browser-qpy) -- wide enough to clear them at any window size (they
    /// don't move), a touch more generous than their tightest possible fit.
    private static let trafficLightReservedWidth: CGFloat = 78

    private func setUpViews() {
        guard let window, let contentView = window.contentView else { return }
        let tabStripHeight: CGFloat = 32
        let toolbarHeight: CGFloat = 36
        let chromeHeight = tabStripHeight + toolbarHeight

        // Hidden titlebar + full-size content view (browser-qpy): the tab
        // strip effectively becomes the titlebar area, with the traffic
        // lights floating over its leading edge (see
        // Self.trafficLightReservedWidth / TabStripView.leadingInset below).
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

        tabStripView.leadingInset = Self.trafficLightReservedWidth
        tabStripView.frame = NSRect(
            x: 0,
            y: contentView.bounds.height - tabStripHeight,
            width: contentView.bounds.width,
            height: tabStripHeight
        )
        tabStripView.autoresizingMask = [.width, .minYMargin]
        tabStripView.delegate = self
        contentView.addSubview(tabStripView)

        toolbarView.frame = NSRect(
            x: 0,
            y: contentView.bounds.height - tabStripHeight - toolbarHeight,
            width: contentView.bounds.width,
            height: toolbarHeight
        )
        toolbarView.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(toolbarView)
        setUpToolbarContents()

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
        let buttonSize: CGFloat = 24
        let margin: CGFloat = 8
        let gap: CGFloat = 4
        let toolbarHeight = toolbarView.bounds.height

        backButton.frame = NSRect(x: margin, y: (toolbarHeight - buttonSize) / 2, width: buttonSize, height: buttonSize)
        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        // Glassy toolbar buttons (browser-qpy): a muted secondary-label
        // glyph sitting borderless on the glass, not the default system-
        // accent-blue tint a plain NSButton image would otherwise pick up.
        backButton.contentTintColor = .secondaryLabelColor
        backButton.target = self
        backButton.action = #selector(goBackAction(_:))
        toolbarView.addSubview(backButton)

        forwardButton.frame = NSRect(
            x: margin + buttonSize + gap,
            y: (toolbarHeight - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )
        forwardButton.isBordered = false
        forwardButton.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Forward")
        forwardButton.contentTintColor = .secondaryLabelColor
        forwardButton.target = self
        forwardButton.action = #selector(goForwardAction(_:))
        toolbarView.addSubview(forwardButton)

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
        omniboxContainerView.addSubview(omniboxField)

        reloadButton.isBordered = false
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.contentTintColor = .secondaryLabelColor
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage(_:))
        omniboxContainerView.addSubview(reloadButton)

        layoutOmniboxContainer()
    }

    /// The pill's outer frame -- centered in the toolbar, width depending on
    /// isOmniboxFocused. Called from setUpToolbarContents, windowDidResize,
    /// and setOmniboxFocused(_:animated:).
    private func omniboxFrame() -> NSRect {
        let toolbarHeight = toolbarView.bounds.height
        let width = isOmniboxFocused ? expandedOmniboxWidth() : Self.omniboxCollapsedWidth
        let x = (toolbarView.bounds.width - width) / 2
        return NSRect(x: x, y: (toolbarHeight - Self.omniboxPillHeight) / 2, width: width, height: Self.omniboxPillHeight)
    }

    /// How wide the expanded pill can get before it would crowd back/forward
    /// on the left or the private-browsing pill (if any) on the right --
    /// never narrower than the collapsed width even in a very small window.
    private func expandedOmniboxWidth() -> CGFloat {
        let margin: CGFloat = 8
        let buttonSize: CGFloat = 24
        let gap: CGFloat = 4
        let leadingReserved = margin + (buttonSize + gap) * 2 + Self.omniboxHorizontalMargin
        let trailingReserved = (privateLabel != nil ? 54 + gap : 0) + margin + Self.omniboxHorizontalMargin
        return max(Self.omniboxCollapsedWidth, toolbarView.bounds.width - leadingReserved - trailingReserved)
    }

    /// Repositions the pill itself (not animated -- see
    /// setOmniboxFocused(_:animated:), the only place that needs the
    /// animated variant) and its inner content (the field + trailing reload
    /// button, which never animate, only snap to their new size).
    private func layoutOmniboxContainer() {
        omniboxContainerView.frame = omniboxFrame()
        layoutOmniboxInnerContent()
    }

    private func layoutOmniboxInnerContent() {
        let width = omniboxContainerView.frame.width
        let reloadSize: CGFloat = 20
        let innerMargin: CGFloat = 8
        reloadButton.frame = NSRect(
            x: width - reloadSize - innerMargin, y: (Self.omniboxPillHeight - reloadSize) / 2,
            width: reloadSize, height: reloadSize
        )
        omniboxField.frame = NSRect(
            x: innerMargin, y: (Self.omniboxPillHeight - 20) / 2,
            width: max(0, width - innerMargin * 2 - reloadSize - 4), height: 20
        )
    }

    /// Just the host, e.g. "example.com" -- what the pill shows while
    /// collapsed/unfocused. Falls back to the raw string if it does not
    /// parse as a URL with a host (e.g. "about:blank", or the empty string
    /// shown for the internal start page -- see Tab.urlString).
    private static func domainOnlyDisplay(for urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host, !host.isEmpty else { return urlString }
        return host
    }

    /// Expands/collapses the pill and swaps the field's displayed text
    /// between the full editable URL (focused) and just the domain
    /// (unfocused) -- called from controlTextDidBeginEditing/
    /// controlTextDidEndEditing below (so both a click into the field and
    /// ⌘L's makeFirstResponder call trigger it identically) and from
    /// commitOmniboxNavigation/Escape's own makeFirstResponder(nil) calls,
    /// which resign the field the same way.
    private func setOmniboxFocused(_ focused: Bool, animated: Bool) {
        guard isOmniboxFocused != focused else { return }
        isOmniboxFocused = focused
        if let tab = activeTab {
            omniboxField.stringValue = focused ? tab.urlString : Self.domainOnlyDisplay(for: tab.urlString)
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
        let tab = Tab(profileName: profile.name, initialURL: url, isPrivate: isPrivate)
        tab.delegate = self
        tabs.append(tab)
        let newIndex = tabs.count - 1
        tabStripView.reload(
            tabs: currentDisplayInfos,
            groups: currentGroupDisplayInfos,
            selectedIndex: makeActive ? newIndex : (activeTabIndex ?? newIndex)
        )
        if makeActive {
            activateTab(at: newIndex)
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
        refreshToolbar(for: tab)
        updateWindowTitle(for: tab)
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
        tabs.remove(at: index)

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
            omniboxField.stringValue = isOmniboxFocused ? tab.urlString : Self.domainOnlyDisplay(for: tab.urlString)
        }
        updateChromeTint(for: tab)
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
        window?.title = isPrivate ? "\(tab.title) — Private Browsing" : "\(tab.title) — \(profile.name)"
    }

    // MARK: - TabDelegate

    func tabDidChangeDisplayState(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabStripView.updateTitle(at: index, title: tab.title)
        tabStripView.updateFavicon(at: index, image: tab.faviconImage)
        tabStripView.updateThemeColor(at: index, hex: tab.themeColorHex)
        if index == activeTabIndex {
            refreshToolbar(for: tab)
            updateWindowTitle(for: tab)
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

    @objc func focusOmnibox(_ sender: Any?) {
        window?.makeFirstResponder(omniboxField)
        omniboxField.currentEditor()?.selectAll(nil)
    }

    /// ⌘⇧C -- the headline feature: copy the active tab's current URL.
    @objc func copyCurrentURL(_ sender: Any?) {
        guard let tab = activeTab else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(tab.urlString, forType: .string)
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
        setOmniboxFocused(true, animated: true)
    }

    /// NSTextFieldDelegate -- fires when the field editor resigns (Escape's
    /// or commitOmniboxNavigation's makeFirstResponder(nil) calls, or a
    /// click elsewhere) -- collapses the pill back to domain-only.
    func controlTextDidEndEditing(_ obj: Notification) {
        setOmniboxFocused(false, animated: true)
    }

    // MARK: - Furniture: history / bookmarks / downloads

    /// ⌘D -- bookmarks the active tab's current page at the top level. No
    /// folder-picker popover (see docs/ai-tasks/m3-furniture-notes.md for
    /// that scope cut) -- use the Bookmarks manager window to file it into a
    /// folder afterward.
    @objc func addBookmark(_ sender: Any?) {
        guard let tab = activeTab else { return }
        let bookmarks = ProfileDataStoreManager.shared.stores(for: profile).bookmarks
        try? bookmarks.addBookmark(title: tab.title, url: tab.urlString, parentId: nil)
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
        for tab in tabs {
            tab.close()
        }
        tabs.removeAll()
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
