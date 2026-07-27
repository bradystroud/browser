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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Orders the window on screen and creates the first tab's CEF browser.
    /// Mirrors the M0 spike's ordering (window on screen, then CreateBrowser)
    /// deliberately -- SetAsChild needs the host view's real frame.
    func show() {
        window?.makeKeyAndOrderFront(nil)
        if tabs.isEmpty {
            addTab(url: initialURL, makeActive: true)
        }
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
            tabs: tabs.map { TabStripView.DisplayInfo(title: $0.title) },
            selectedIndex: makeActive ? newIndex : (activeTabIndex ?? newIndex)
        )
        if makeActive {
            activateTab(at: newIndex)
        }
        return tab
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        activateTab(at: index)
    }

    private func activateTab(at index: Int, updateStrip: Bool = true) {
        guard tabs.indices.contains(index) else { return }

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
            tabs: tabs.map { TabStripView.DisplayInfo(title: $0.title) },
            selectedIndex: newActiveIndex
        )

        if wasActive {
            activeTabIndex = nil
            activateTab(at: newActiveIndex, updateStrip: false)
        } else {
            activeTabIndex = newActiveIndex
        }
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
        if index == activeTabIndex {
            refreshToolbar(for: tab)
            updateWindowTitle(for: tab)
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
        addTab(url: "https://example.com", makeActive: true)
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
        guard !text.isEmpty, let tab = activeTab else { return }
        let resolved = Self.resolveOmniboxSubmission(text)
        // End editing (and only then set the resolved text) before touching
        // CEF: ending the field's edit session re-syncs stringValue from the
        // (stale, pre-resolution) field editor buffer, which would otherwise
        // clobber a value set while still editing.
        window?.makeFirstResponder(nil)
        omniboxField.stringValue = resolved
        // Deferred a run-loop turn because Return's key-event dispatch runs
        // this method synchronously from deep inside AppKit's Text Services
        // Manager machinery, and calling into CEF from that exact stack risks
        // a second, independent reentrancy hazard beyond the one below this
        // sidesteps -- see docs/ai-tasks/m1-shell-notes.md's "known issue" on
        // BRWClientHandler::LoadURLWhenReady for the deeper, still-open bug
        // this does NOT fix: CefFrame::LoadURL re-navigating an existing
        // frame hangs regardless of which call stack invokes it.
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
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if let tab = activeTab {
            omniboxField.stringValue = tab.urlString
        }
        window?.makeFirstResponder(nil)
        return true
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        for tab in tabs {
            tab.close()
        }
        tabs.removeAll()
        onWindowClosed?()
    }
}
