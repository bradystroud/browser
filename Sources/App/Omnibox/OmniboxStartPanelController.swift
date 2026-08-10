import AppKit

/// A borderless panel that never takes key status, so the omnibox's field
/// editor keeps first responder for the whole time it's open -- identical
/// reasoning to OmniboxAutocompleteController's own AutocompletePanel (mouse
/// events reach a non-key window perfectly well; keyboard focus staying in
/// the omnibox is the whole point).
private final class StartPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Safari-style omnibox focus panel (browser-5kq.9): focusing the address bar
/// drops down a mini start page -- the Favourites grid, with Recently Visited
/// underneath -- and typing anything replaces it with the ordinary
/// autocomplete dropdown.
///
/// Deliberately owns nothing in BrowserWindowController and is never
/// referenced from it: it attaches purely by observing notifications, the way
/// ReaderModeController/PasswordManagerCoordinator attach floating UI without
/// owning the window.
///
/// - Shown on `OmniboxField.didFocusNotification`, posted by the field itself
///   when it takes focus (a click, or ⌘L / a new tab's automatic focus).
/// - Hidden again on `NSControl.textDidChangeNotification` (the user typed --
///   this is strictly the empty-input state, so it can never fight with the
///   autocomplete dropdown, which only ever appears once there's a query) and
///   on `NSControl.textDidEndEditingNotification` (blur, which is also how
///   Escape and a click into the page reach us -- see
///   BrowserWindowController's own cancelOperation handling, which resigns
///   the field).
///
/// Not shown at all in a Private window, matching StartPageRenderer's private
/// start page: there's no profile history/favourites story that belongs in a
/// private window, and reaching for a real profile's stores from one is
/// exactly what that page deliberately avoids.
final class OmniboxStartPanelController {
    static let shared = OmniboxStartPanelController()

    private static let maxWidth: CGFloat = 560
    private static let minWidth: CGFloat = 360
    /// Gap between the omnibox pill and the panel's top edge.
    private static let anchorGap: CGFloat = 10
    private static let screenMargin: CGFloat = 12

    private var panel: NSPanel?
    private weak var anchorField: NSTextField?
    /// The field's text at the moment the panel opened. Focusing the omnibox
    /// swaps in the full URL (OmniboxField.becomeFirstResponder), and if
    /// AppKit ever turns that programmatic write into a textDidChange, this
    /// is what tells it apart from a real keystroke.
    private var textAtShow = ""
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    /// Replaces what `addChildWindow` used to provide -- see
    /// AnchoredPanelTracker (browser-5kq.10).
    private var tracker: AnchoredPanelTracker?
    /// The panel's content height, kept so a reposition after an anchor-window
    /// move doesn't have to rebuild the content to measure it again.
    private var contentHeight: CGFloat = 0

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(fieldDidFocus(_:)),
            name: OmniboxField.didFocusNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(fieldTextDidChange(_:)),
            name: NSControl.textDidChangeNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(fieldTextDidEndEditing(_:)),
            name: NSControl.textDidEndEditingNotification, object: nil
        )
    }

    // MARK: - Notification handling

    @objc private func fieldDidFocus(_ notification: Notification) {
        guard let field = notification.object as? OmniboxField else { return }
        let textAtFocus = field.stringValue
        // Deferred a run-loop turn deliberately: this fires from inside
        // becomeFirstResponder, mid-responder-chain, and adding a child
        // window from there is asking for trouble. It also lets the pill's
        // focus-expand layout settle first.
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field else { return }
            // A keystroke landed before this turn ran -- the user is already
            // typing, which is the autocomplete dropdown's state, not ours.
            guard field.stringValue == textAtFocus else { return }
            // Either form counts as focused: normally AppKit has swapped in
            // the field editor by now, but the field itself can still be
            // first responder in a window that isn't key (which is exactly
            // the state an agent's --test-no-activate launch is in).
            guard let window = field.window,
                  window.firstResponder === field.currentEditor() || window.firstResponder === field else { return }
            self.show(for: field)
        }
    }

    @objc private func fieldTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === anchorField else { return }
        guard field.stringValue != textAtShow else { return }
        dismiss()
    }

    @objc private func fieldTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === anchorField else { return }
        dismiss()
    }

    // MARK: - Show / dismiss

    private func show(for field: NSTextField) {
        dismiss()
        guard let window = field.window,
              let controller = window.windowController as? BrowserWindowController,
              !controller.isPrivate else { return }

        let profileId = controller.profile.id
        let settings = StartPageSettingsStore.load(forProfileId: profileId)
        let sections = StartPageSections.build(
            profileId: profileId, settings: settings, historyKind: .recentlyVisited
        )
        // Both start-page sections switched off in Settings: the user has
        // said they don't want this content, so the panel stays out of the
        // way entirely rather than dropping an empty sheet down on every
        // click into the omnibox. (An *enabled* but empty section still
        // shows, with its own actionable empty message -- browser-5kq.7.)
        guard !sections.isEmpty else { return }

        let width = min(Self.maxWidth, max(Self.minWidth, window.frame.width - 80))
        let contentView = OmniboxStartPanelView(
            sections: sections, profileId: profileId, width: width
        ) { [weak self] url, modifiers in
            self?.activate(url: url, modifiers: modifiers)
        }

        let panel = StartPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: contentView.frame.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Floats above the browser window by *level*, not by being its child
        // -- see AnchoredPanelTracker for the crash that rules child windows
        // out here entirely (browser-5kq.10).
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true

        // Real content goes inside the glass's contentContainer, never as a
        // sibling subview -- browser-0y1: a sibling can composite underneath
        // NSGlassEffectView's own blur pass on macOS 26 and render blurred or
        // missing. GlassBackgroundView also handles the Reduce Transparency
        // solid fallback and the pre-26 NSVisualEffectView path for free.
        let glass = GlassBackgroundView(
            material: .popover, blendingMode: .behindWindow,
            solidFallbackColor: .windowBackgroundColor, cornerRadius: 12
        )
        glass.frame = NSRect(x: 0, y: 0, width: width, height: contentView.frame.height)
        glass.autoresizingMask = [.width, .height]

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = contentView
        // Pinned with constraints rather than an autoresizing mask, because
        // GlassBackgroundView's contentContainer is still zero-sized at this
        // point on the macOS 26 path -- it's NSGlassEffectView's `contentView`,
        // which that view only sizes at its own next layout pass, after this
        // code has run. An autoresizing subview added to a zero-sized parent
        // gets the parent's entire eventual size added to its own frame,
        // which made this scroll view exactly twice the panel's size and left
        // every tile laid out off the visible edge -- confirmed live via a
        // frame dump, and the reason this panel first rendered as empty glass.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        glass.contentContainer.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: glass.contentContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: glass.contentContainer.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: glass.contentContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: glass.contentContainer.bottomAnchor),
        ])

        panel.contentView = glass
        self.panel = panel
        anchorField = field
        textAtShow = field.stringValue

        contentHeight = contentView.frame.height
        position(panel, in: window, controller: controller, contentHeight: contentHeight)
        panel.orderFront(nil)

        installMonitors()
        tracker = AnchoredPanelTracker(
            anchorWindow: window,
            onReposition: { [weak self] in self?.reposition() },
            onDismiss: { [weak self] in self?.dismiss() }
        )
    }

    /// Re-applies the panel's frame after the anchor window moved or resized
    /// -- the work `addChildWindow` used to do for free (browser-5kq.10).
    /// A resize can also change how many tile columns fit, which this does
    /// *not* re-flow; the panel is short-lived enough that keeping it
    /// correctly anchored is what matters.
    private func reposition() {
        guard let panel, let window = anchorField?.window,
              let controller = window.windowController as? BrowserWindowController else { return }
        position(panel, in: window, controller: controller, contentHeight: contentHeight)
    }

    private func dismiss() {
        removeMonitors()
        tracker?.stop()
        tracker = nil
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        anchorField = nil
        textAtShow = ""
        contentHeight = 0
    }

    /// Anchors the panel just below all of the window's chrome
    /// (BrowserWindowController.contentAreaTopY -- the toolbar/omnibox row
    /// *and* the tab strip), horizontally centered on the window, which is
    /// also where the omnibox pill itself is centered (see that class's
    /// omniboxFrame()). Deliberately not measured from the pill's own live
    /// frame: that frame is mid-animation at exactly this moment, since
    /// focus expands the pill. Being a separate child window, the panel may
    /// overlap the web content area freely -- CEF's compositing only paints
    /// over AppKit views inside the same window.
    ///
    /// Height is capped at the room actually available above the bottom of
    /// the screen; the content scrolls inside whatever is left.
    private func position(_ panel: NSPanel, in window: NSWindow, controller: BrowserWindowController, contentHeight: CGFloat) {
        let chromeBottomInWindow = NSPoint(x: 0, y: controller.contentAreaTopY)
        // Falls back to the window's own frame, never NSScreen.main, when the
        // window isn't on any screen: an offscreen window (--test-no-activate
        // parks one at -3000,-3000) would otherwise have its panel yanked
        // onto the real display, on top of whatever else is there.
        let visibleFrame = window.screen?.visibleFrame ?? window.frame
        let topY = window.convertPoint(toScreen: chromeBottomInWindow).y - Self.anchorGap
        let available = topY - visibleFrame.minY - Self.screenMargin
        let height = max(80, min(contentHeight, available))
        let width = panel.frame.width
        var x = window.frame.midX - width / 2
        x = min(max(x, visibleFrame.minX + Self.screenMargin), visibleFrame.maxX - width - Self.screenMargin)
        panel.setFrame(NSRect(x: x, y: topY - height, width: width, height: height), display: true)
    }

    // MARK: - Activation

    private func activate(url: String, modifiers: NSEvent.ModifierFlags) {
        guard let field = anchorField, let window = field.window,
              let controller = window.windowController as? BrowserWindowController else {
            dismiss()
            return
        }
        dismiss()
        // Blur first: this is the same "commit and get out of the omnibox"
        // shape Enter already has, and it's what restores the collapsed pill
        // display (BrowserWindowController.controlTextDidEndEditing).
        window.makeFirstResponder(nil)

        if modifiers.contains(.command) {
            // Same ⌘-click / ⌘⇧-click convention as a real link click --
            // see docs/ai-tasks/link-click-new-tab-notes.md.
            controller.openTabForLinkClick(
                url: url,
                afterIndex: controller.activeTabIndex ?? 0,
                foreground: modifiers.contains(.shift)
            )
        } else if let tab = controller.activeTab {
            tab.load(url: url)
        } else {
            controller.addTab(url: url, makeActive: true)
        }
    }

    // MARK: - Dismiss monitors

    private func installMonitors() {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let panel = self.panel else { return event }
            // Clicks inside the panel are the tiles' own business.
            if event.window === panel { return event }
            // A click back into the omnibox itself isn't "outside": the
            // field keeps focus, so the panel should stay up.
            if let field = self.anchorField, event.window === field.window,
               field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                return event
            }
            self.dismiss()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
    }

}
