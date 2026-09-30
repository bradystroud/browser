import AppKit

/// Borderless panels don't take key status by default, and this one has to --
/// arrow keys, Return, Escape and type-to-filter all arrive as ordinary
/// keyDowns to its first responder (the list view). Same reasoning as
/// ShortcutsOverlayController's panel, which is also key while it's up.
private final class ProfileSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// ⌃⌘N -- the profile quick-switcher (browser-sdj.2). Brady: "a shortcut
/// that brings up a little dialogue that has the different profiles, and I
/// can use the arrow keys to pick one and press enter and it opens a new
/// window in that profile [...] and if there's already a window open with
/// that profile, it should just take me to that."
///
/// A standalone floating `NSPanel` ordered front by window level -- **never**
/// a child window. `NSWindow.addChildWindow` rebuilds the anchor window's
/// whole ordering group and walks every window already in it, which took an
/// out-of-process `NSRemoteView` (and the entire browser) down with it once
/// already (browser-5kq.10; see CLAUDE.md's engine facts).
///
/// Opened from a real menu item (Profiles > Switch Profile…) rather than an
/// NSEvent monitor: the shortcut carries Command, so AppKit's ordinary
/// key-equivalent routing reaches it reliably from anywhere in the app --
/// including while a web page has focus -- and a menu item is discoverable,
/// which a monitor isn't. (Bare, non-Command shortcuts are the case that
/// needs a monitor instead; see TabCyclingController.)
final class ProfileSwitcherController {
    static let shared = ProfileSwitcherController()

    private var panel: NSPanel?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var appDeactivateObserver: NSObjectProtocol?

    private var isShowing: Bool { panel != nil }

    private init() {}

    /// Pressing the shortcut again while the panel is up closes it, matching
    /// ShortcutsOverlayController's ⌘/.
    func toggle(relativeTo parentWindow: NSWindow?) {
        if isShowing {
            dismiss()
        } else {
            show(relativeTo: parentWindow)
        }
    }

    // MARK: - Show / dismiss

    private func show(relativeTo parentWindow: NSWindow?) {
        guard panel == nil else { return }
        let currentProfileId = (parentWindow?.windowController as? BrowserWindowController)?.profile.id

        let items = ProfileManager.shared.profiles.map {
            ProfileSwitcherListView.Item(
                profile: $0,
                hasOpenWindow: WindowManager.shared.frontmostWindowController(forProfileId: $0.id) != nil
            )
        }
        guard !items.isEmpty else { return }

        // Selection starts on the first profile that *isn't* the one the
        // current window is already in: this exists to get somewhere else, so
        // pressing ⌃⌘N then Return immediately should do something. Falls
        // back to the first row when there's only one profile, or when the
        // switcher was opened with no browser window at all.
        let initialIndex = items.firstIndex { $0.profile.id != currentProfileId } ?? 0

        let listView = ProfileSwitcherListView(items: items, selectedIndex: initialIndex)
        listView.onCommit = { [weak self] profile in self?.commit(profile) }
        listView.onCancel = { [weak self] in self?.dismiss() }
        listView.onHeightChange = { [weak self] height in self?.resize(toContentHeight: height) }

        let size = NSSize(width: ProfileSwitcherListView.width, height: listView.frame.height)
        let panel = ProfileSwitcherPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        // NSPanel defaults this to true; switched off deliberately so app
        // deactivation goes through this controller's own dismissal below
        // (which tears the panel down properly) instead of AppKit silently
        // hiding a panel that stays "showing" as far as `panel` here is
        // concerned -- the state ⌃⌘N's toggle reads.
        panel.hidesOnDeactivate = false

        // Real content lives inside the glass's contentContainer, never as a
        // sibling subview -- browser-0y1: on macOS 26 a sibling can composite
        // underneath NSGlassEffectView's own blur pass and render blurred or
        // missing. GlassBackgroundView also gives the Reduce Transparency
        // solid fallback and the pre-26 NSVisualEffectView path for free.
        let glass = GlassBackgroundView(
            material: .popover, blendingMode: .behindWindow,
            solidFallbackColor: .windowBackgroundColor, cornerRadius: 14
        )
        glass.frame = NSRect(origin: .zero, size: size)
        glass.autoresizingMask = [.width, .height]

        // Constraints, not an autoresizing mask: contentContainer is
        // NSGlassEffectView's `contentView` on the macOS 26 path and is still
        // zero-sized at this point (it's only sized at that view's next
        // layout pass), and an autoresizing subview added to a zero-sized
        // parent gets the parent's entire eventual size added to its own
        // frame -- see OmniboxStartPanelController for the live confirmation
        // of that, which rendered a panel as empty glass.
        listView.translatesAutoresizingMaskIntoConstraints = false
        glass.contentContainer.addSubview(listView)
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: glass.contentContainer.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: glass.contentContainer.trailingAnchor),
            listView.topAnchor.constraint(equalTo: glass.contentContainer.topAnchor),
            listView.bottomAnchor.constraint(equalTo: glass.contentContainer.bottomAnchor),
        ])

        panel.contentView = glass
        self.panel = panel

        position(panel, relativeTo: parentWindow)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(listView)

        installDismissMonitors(panel)
    }

    /// Centered on the window it was invoked from, biased slightly above
    /// centre the way system pickers are. Falls back to the panel's own
    /// `center()` only when there's no window to anchor to -- deliberately
    /// never `NSScreen.main`, which for an offscreen `--test-no-activate`
    /// window would yank the panel onto the real display.
    private func position(_ panel: NSPanel, relativeTo parentWindow: NSWindow?) {
        guard let parentWindow else {
            panel.center()
            return
        }
        let parentFrame = parentWindow.frame
        panel.setFrameOrigin(NSPoint(
            x: parentFrame.midX - panel.frame.width / 2,
            y: parentFrame.midY - panel.frame.height / 2 + parentFrame.height * 0.12
        ))
    }

    /// Type-to-filter changed the row count. The panel's top edge stays put
    /// while it grows or shrinks downward, so the list doesn't jump around
    /// under the cursor as matches are narrowed.
    private func resize(toContentHeight height: CGFloat) {
        guard let panel else { return }
        let top = panel.frame.maxY
        panel.setFrame(
            NSRect(x: panel.frame.minX, y: top - height, width: panel.frame.width, height: height),
            display: true
        )
    }

    private func dismiss() {
        removeDismissMonitors()
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
    }

    // MARK: - Commit

    /// The whole point of the feature: an existing window for that profile is
    /// brought forward rather than duplicated. A new window opens on the
    /// internal start page ("about:blank" is Tab's own sentinel for it, see
    /// Tab.resolveInitialLoad) -- deliberately *not*
    /// WindowManager.openNewWindow's default `initialURL`, which is still an
    /// M1-era https://example.com placeholder.
    private func commit(_ profile: Profile) {
        dismiss()
        if let existing = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) {
            // Skipped under --test-no-activate for the same reason
            // WindowManager.registerAndShow skips it: activating steals real
            // keyboard focus on the actual display, which is exactly what
            // that flag exists to avoid for contained test launches.
            if !CommandLineArgs.testNoActivate() {
                AppActivation.activate()
            }
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            WindowManager.shared.openNewWindow(profile: profile, initialURL: "about:blank")
        }
    }

    // MARK: - Dismiss monitors

    private func installDismissMonitors(_ panel: NSPanel) {
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Clicks inside the panel are the list view's own business.
            guard let self, let panel = self.panel, event.window !== panel else { return event }
            self.dismiss()
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        // Switching to another app (⌘Tab, clicking another app's window)
        // ends the interaction -- a floating panel at `.floating` level would
        // otherwise sit on top of whatever the user moved to.
        //
        // Deliberately the *application's* deactivation, not the panel's own
        // NSWindow.didResignKeyNotification: an ordinary browser window can
        // take key back from the panel milliseconds after it opens, entirely
        // on its own (a window opened moments earlier finishes creating its
        // engine tab and focuses its omnibox), and dismissing on that made
        // the panel vanish immediately after appearing -- observed live, and
        // intermittent, which is exactly how this would have reached Brady.
        // Clicks on another of *our* windows are already covered by the mouse
        // monitors above.
        appDeactivateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func removeDismissMonitors() {
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let appDeactivateObserver { NotificationCenter.default.removeObserver(appDeactivateObserver) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        appDeactivateObserver = nil
    }
}
