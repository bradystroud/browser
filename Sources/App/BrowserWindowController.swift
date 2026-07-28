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
    private(set) var tabs: [Tab] = []
    private(set) var activeTabIndex: Int?

    /// Set by WindowManager so it can drop this controller from its list.
    var onWindowClosed: (() -> Void)?

    private let initialURL: String

    private let tabStripView = TabStripView(frame: .zero)
    private let toolbarView = NSView()
    private let backButton = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton = NSButton()
    private let omniboxField = NSTextField()
    private let profileDotView: ProfileDotView
    private let contentContainerView = NSView()
    private let autocomplete = OmniboxAutocompleteController()
    private let permissionPrompt = PermissionPromptController()
    /// The tab + promptId a permission request is currently showing UI for,
    /// so a CEF-initiated dismiss (engineTabDidDismissPermissionRequest) for
    /// an unrelated/stale promptId doesn't tear down a newer prompt.
    private var pendingPermissionRequest: (tab: Tab, promptId: UInt64)?

    var activeTab: Tab? {
        guard let index = activeTabIndex, tabs.indices.contains(index) else { return nil }
        return tabs[index]
    }

    init(profile: Profile, initialURL: String) {
        self.profile = profile
        self.initialURL = initialURL
        self.profileDotView = ProfileDotView(colorHex: profile.colorHex)

        let window = BrowserWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Browser — \(profile.name)"
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
    /// `restoring`/`activeIndex`, when non-empty, recreate a session-restored
    /// window's tabs instead of the usual single `initialURL` tab -- see
    /// WindowManager.restoreSession. All restored tabs are added inactive
    /// first and only the designated active one is then explicitly
    /// activated, so inactive tabs' CefBrowsers stay lazily uncreated until
    /// the user actually clicks over to one (Tab.createBrowserIfNeeded is a
    /// no-op until then) -- restoring 20 background tabs doesn't spin up 20
    /// CefBrowsers at launch. Each also skips the "new tab focuses omnibox"
    /// UX (Tab.needsInitialOmniboxFocus) -- that's for a user deliberately
    /// opening a new tab, not an automatic relaunch.
    func show(restoring restoreTabs: [SessionSnapshot.Tab] = [], activeIndex: Int = 0) {
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

        for restoreTab in restoreTabs {
            let tab = addTab(url: restoreTab.url, makeActive: false)
            tab.needsInitialOmniboxFocus = false
            tab.seedRestoredTitle(restoreTab.title)
        }
        let validIndex = tabs.indices.contains(activeIndex) ? activeIndex : 0
        tabStripView.reload(
            tabs: tabs.map { TabStripView.DisplayInfo(title: $0.title, favicon: $0.faviconImage) },
            selectedIndex: validIndex
        )
        activateTab(at: validIndex)
    }

    // MARK: - View setup

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }
        let tabStripHeight: CGFloat = 32
        let toolbarHeight: CGFloat = 36

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
        forwardButton.target = self
        forwardButton.action = #selector(goForwardAction(_:))
        toolbarView.addSubview(forwardButton)

        reloadButton.frame = NSRect(
            x: margin + (buttonSize + gap) * 2,
            y: (toolbarHeight - buttonSize) / 2,
            width: buttonSize,
            height: buttonSize
        )
        reloadButton.isBordered = false
        reloadButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload")
        reloadButton.target = self
        reloadButton.action = #selector(reloadPage(_:))
        toolbarView.addSubview(reloadButton)

        let profileDotMargin: CGFloat = 10
        profileDotView.frame.origin = NSPoint(
            x: toolbarView.bounds.width - profileDotView.frame.width - profileDotMargin,
            y: (toolbarHeight - profileDotView.frame.height) / 2
        )
        profileDotView.autoresizingMask = [.minXMargin]
        toolbarView.addSubview(profileDotView)

        let omniboxX = margin + (buttonSize + gap) * 3 + gap
        let omniboxWidth = profileDotView.frame.minX - gap * 2 - omniboxX
        omniboxField.frame = NSRect(x: omniboxX, y: (toolbarHeight - 24) / 2, width: max(0, omniboxWidth), height: 24)
        omniboxField.autoresizingMask = [.width]
        omniboxField.placeholderString = "Search or enter website name"
        omniboxField.target = self
        omniboxField.action = #selector(omniboxSubmitted)
        omniboxField.delegate = self
        toolbarView.addSubview(omniboxField)
    }

    // MARK: - Tabs

    @discardableResult
    func addTab(url: String, makeActive: Bool) -> Tab {
        let tab = Tab(profileName: profile.name, initialURL: url)
        tab.delegate = self
        tabs.append(tab)
        let newIndex = tabs.count - 1
        tabStripView.reload(
            tabs: tabs.map { TabStripView.DisplayInfo(title: $0.title, favicon: $0.faviconImage) },
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

    func closeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let wasActive = index == activeTabIndex

        tabs[index].hostView.removeFromSuperview()
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

        tabStripView.reload(
            tabs: tabs.map { TabStripView.DisplayInfo(title: $0.title, favicon: $0.faviconImage) },
            selectedIndex: newActiveIndex
        )

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

    private func refreshToolbar(for tab: Tab) {
        backButton.isEnabled = tab.canGoBack
        forwardButton.isEnabled = tab.canGoForward
        if omniboxField.currentEditor() == nil {
            omniboxField.stringValue = tab.urlString
        }
    }

    private func updateWindowTitle(for tab: Tab) {
        window?.title = "\(tab.title) — \(profile.name)"
    }

    // MARK: - TabDelegate

    func tabDidChangeDisplayState(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabStripView.updateTitle(at: index, title: tab.title)
        tabStripView.updateFavicon(at: index, image: tab.faviconImage)
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

    // MARK: - Menu / keyboard actions (reached via the responder chain --
    // NSWindowController is automatically next-responder after its window).

    @objc func newTab(_ sender: Any?) {
        // Blank page + focused, selected address bar is the standard new-tab
        // UX -- loading a real page here would fight with the omnibox-focus
        // flow (the user is about to type over it anyway).
        addTab(url: "about:blank", makeActive: true)
    }

    @objc func closeTab(_ sender: Any?) {
        guard let index = activeTabIndex else { return }
        closeTab(at: index)
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard let current = activeTabIndex, !tabs.isEmpty else { return }
        selectTab(at: (current + 1) % tabs.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard let current = activeTabIndex, !tabs.isEmpty else { return }
        selectTab(at: (current - 1 + tabs.count) % tabs.count)
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
        // No incognito-style contexts exist yet (see AGENTS.md/plan) -- once
        // one is added, this is where a "don't record" check belongs.
        let history = ProfileDataStoreManager.shared.stores(for: profile).history
        try? history.recordVisit(url: url, title: tab.title)
        if let appDelegate = NSApp.delegate as? AppDelegate, tab === activeTab {
            appDelegate.mainMenuBuilder.rebuildRecentHistory(for: profile)
        }
        WindowManager.shared.scheduleSessionSave()
    }

    func tab(_ tab: Tab, didBeginDownload info: TabDownloadStart) {
        DownloadCoordinator.shared.beginDownload(profile: profile, info: info)
    }

    func tab(_ tab: Tab, didUpdateDownload info: TabDownloadUpdate) {
        DownloadCoordinator.shared.updateDownload(profile: profile, info: info)
    }

    /// A page wants camera/microphone/location/notification permission --
    /// see EngineTabDelegate.engineTabDidRequestPermission for the full
    /// contract. Checks PermissionStore for a remembered per-origin decision
    /// first; only shows the Safari-style prompt popover if none exists yet.
    func tab(_ tab: Tab, didRequestPermission kinds: EnginePermissionKind, promptId: UInt64, requestingOrigin: String, decision: @escaping (Bool) -> Void) {
        let store = PermissionStoreManager.shared.store(for: profile)
        if let remembered = store.decision(for: requestingOrigin, kinds: kinds) {
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
            store.setDecision(allow, for: requestingOrigin, kinds: kinds)
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
    }
}
