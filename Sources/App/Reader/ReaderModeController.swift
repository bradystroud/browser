import AppKit

/// Reader mode (browser-5kq.1): a floating "Reader" button that appears
/// when the active tab's page looks article-ish, toggling a client-side
/// Readability.js transformation of the current page. One instance per
/// `BrowserWindow` (see that file's own doc comments for why this owns its
/// floating UI directly rather than anything in `BrowserWindowController`).
///
/// The three things that can change whether the button should be showing --
/// the active tab changed, it navigated, it finished loading -- are all
/// TabLifecycleEvents now (browser-g6d), so the button is re-evaluated
/// exactly when one of them happens. This used to be a 400ms poll that
/// re-derived those same three transitions by comparing tab identity + URL +
/// loading state against what it last saw; see docs/ai-tasks/
/// reader-mode-notes.md for that original reasoning and docs/ai-tasks/
/// tab-lifecycle-notifications-notes.md for the move off it.
///
/// The 400ms settle delay in checkReaderable(for:) below is a different
/// thing entirely and stays: it's waiting for a fire-and-forget injected
/// script to run in the renderer, which no lifecycle event can tell us about.
final class ReaderModeController: NSObject, TabLifecycleObserver {
    private weak var window: NSWindow?
    private var buttonView: NSButton?

    private var isReaderActive = false
    private weak var activeReaderTab: Tab?

    func attach(to window: NSWindow) {
        self.window = window
        TabLifecycleCenter.shared.addObserver(self)
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        guard controller === windowController else { return }
        switch event {
        case .becameActive, .navigated, .finishedLoading:
            evaluate(tab)
        case .closed:
            // Otherwise a stale isReaderActive would make the *next* tab to
            // become active show its button in the active (tinted) state.
            if tab === activeReaderTab {
                isReaderActive = false
                activeReaderTab = nil
            }
        case .opened:
            break
        }
    }

    private var windowController: BrowserWindowController? {
        window?.windowController as? BrowserWindowController
    }

    private func currentTab() -> Tab? {
        windowController?.activeTab
    }

    /// Decides what this window's Reader button should look like right now,
    /// given `tab` (only ever the window's own active tab -- a background
    /// tab's navigation/load says nothing about the button on screen).
    private func evaluate(_ tab: Tab) {
        guard tab === currentTab() else { return }

        if isReaderActive, tab === activeReaderTab {
            // Don't re-check readerability on our own generated reader page
            // -- document.write already replaced the DOM with our own
            // template, which Readability's heuristic wasn't designed to
            // evaluate, and the button should stay shown (as "active")
            // regardless of what that check would say.
            setButtonVisible(true, active: true)
            return
        }
        if tab.isLoading {
            setButtonVisible(false)
            return
        }
        checkReaderable(for: tab)
    }

    private func checkReaderable(for tab: Tab) {
        guard tab.urlString.hasPrefix("http://") || tab.urlString.hasPrefix("https://") else {
            setButtonVisible(false)
            return
        }
        tab.executeJavaScript(ReaderTemplate.readerableProbeScript)
        // Small settle delay for the fire-and-forget probe script above to
        // actually run in the renderer before reading the page source back
        // -- see docs/ai-tasks/reader-mode-notes.md for why there's no
        // result-path alternative to this wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak tab] in
            guard let self, let tab, tab === self.currentTab() else { return }
            tab.getPageSource { [weak self, weak tab] source in
                guard let self, let tab, tab === self.currentTab() else { return }
                let readerable = source.map(ReaderTemplate.isMarkedReaderable(inSource:)) ?? false
                self.setButtonVisible(readerable)
            }
        }
    }

    // MARK: - Toggle

    @objc func toggle() {
        guard let tab = currentTab() else { return }
        if isReaderActive, tab === activeReaderTab {
            exitReaderMode(for: tab)
        } else {
            enterReaderMode(for: tab)
        }
    }

    private func enterReaderMode(for tab: Tab) {
        tab.executeJavaScript(ReaderTemplate.activationScript(fontScale: ReaderFontSizePreference.current.scale))
        isReaderActive = true
        activeReaderTab = tab
        setButtonVisible(true, active: true)
    }

    private func exitReaderMode(for tab: Tab) {
        isReaderActive = false
        activeReaderTab = nil
        // A real network reload is what actually restores the live page --
        // document.write only ever replaced the in-memory DOM, never
        // navigated away from the original URL.
        tab.reload()
        setButtonVisible(false)
    }

    func setFontSize(_ size: ReaderFontSize) {
        ReaderFontSizePreference.current = size
        guard isReaderActive, let tab = activeReaderTab else { return }
        tab.executeJavaScript(ReaderTemplate.setFontScaleScript(size.scale))
    }

    // MARK: - Floating button

    private func setButtonVisible(_ visible: Bool, active: Bool = false) {
        guard let window, let contentView = window.contentView else { return }
        if buttonView == nil {
            // Vertically centered within the toolbar row itself -- NOT
            // hanging down into the content area (that region is covered by
            // CEF's own hosted content view regardless of normal AppKit
            // z-order, confirmed by trial: identical button, invisible
            // there, visible here) and NOT reaching into the tab strip
            // (where it would land right back on top of the mute/close
            // buttons this was reported overlapping in the first place).
            // See BrowserWindowController.toolbarRowHeight's own doc
            // comment.
            guard let controller = windowController else { return }
            let button = NSButton(
                image: NSImage(systemSymbolName: "doc.plaintext", accessibilityDescription: "Reader")!,
                target: self, action: #selector(toggle)
            )
            button.applyChromeAppearance(.glass)
            button.toolTip = "Show Reader"
            button.frame = controller.trailingToolbarControlFrame(slot: 0)
            button.autoresizingMask = [.minXMargin, .minYMargin]
            contentView.addSubview(button)
            buttonView = button
        }
        buttonView?.isHidden = !visible
        buttonView?.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
        buttonView?.toolTip = active ? "Hide Reader" : "Show Reader"
    }
}
