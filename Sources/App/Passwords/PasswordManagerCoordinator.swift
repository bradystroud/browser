import AppKit

private struct PasswordFormSubmitPayload: Decodable {
    let origin: String
    let username: String
    let password: String
}

private struct PasswordFieldsPresentPayload: Decodable {
    let present: Bool
}

/// App-wide singleton that registers with PageMessageDispatcher for the
/// password-manager's page-message types, and owns the one save-password
/// popover shown at a time across the whole app.
///
/// Only owns its own lightweight per-window icon-refresh poll now -- tab
/// discovery/wiring moved to PageMessageDispatcher once card/address
/// autofill (browser-ojh.2) became a second consumer of tabs' page
/// messages (see that class's own doc comment for why two independent
/// pollers wiring the same Tab.onPageMessage closure would silently race).
/// The icon-refresh poll still needs to exist here, separately: "does the
/// active tab have a saved credential for its current origin" isn't
/// something a page message tells this coordinator about on its own (it
/// depends on navigation, not just form-field events), so it's re-checked
/// every tick the same way ReaderModeController re-checks its own Reader
/// button's visibility every tick -- see that class's own doc comment for
/// why polling is the right call here with BrowserWindowController
/// off-limits.
final class PasswordManagerCoordinator: NSObject {
    static let shared = PasswordManagerCoordinator()

    private var pollTimer: Timer?
    private let savePrompt = SavePasswordPromptController()
    private var anchorViews = NSMapTable<NSView, NSView>.weakToWeakObjects()

    /// Latest "does this tab's current page have a password field" signal
    /// from PasswordDetectionScript's MutationObserver (the
    /// "passwordFieldsPresent" cefQuery message) -- keyed by Tab identity
    /// rather than origin string, so a stale signal from a page the tab has
    /// since navigated away from can't accidentally apply to the new page
    /// (a fresh document-start injection always re-reports its own
    /// presence state before anything else happens). Read by
    /// updateKeyButton(for:) to decide whether the autofill key icon should
    /// show at all -- a saved credential existing isn't by itself enough;
    /// the current page needs to actually have somewhere to fill it into.
    private var passwordFieldPresence = NSMapTable<Tab, NSNumber>.weakToStrongObjects()

    /// One floating "key" button per window content view -- shown when the
    /// window's active tab both has a detected password field and a saved
    /// credential for its origin. Same per-window floating-button pattern
    /// as ReaderModeController's Reader button (see that class's own doc
    /// comment for why this lives here rather than in
    /// BrowserWindowController's toolbar).
    private var keyButtons = NSMapTable<NSView, NSButton>.weakToWeakObjects()
    /// Reverse lookup from a key button back to its owning window, since
    /// the button's own @objc action only receives the button (the AppKit
    /// sender) -- re-deriving the *current* active tab from the window at
    /// click time (rather than capturing a tab reference when the button
    /// was created) means a tab switch between the icon appearing and the
    /// user clicking it can't fill the wrong page.
    private var windowForKeyButton = NSMapTable<NSButton, NSWindow>.weakToWeakObjects()

    /// Matches FindBarController/ReaderModeController's hardcoded
    /// tab-strip (32) + toolbar (36) height constant -- see
    /// FindBarController.contentTopInset's doc comment for why this is
    /// duplicated rather than shared across files.
    private static let contentTopInset: CGFloat = 32 + 36
    private static let keyButtonSize: CGFloat = 26

    private override init() {}

    /// Idempotent -- called from BrowserWindow.swift's init (see that
    /// file's own doc comments for why new per-feature wiring lives there
    /// rather than in BrowserWindowController/AppDelegate), so the first
    /// browser window created in the process starts this ticking, with no
    /// separate explicit call site needed anywhere else.
    func activate() {
        PageMessageDispatcher.shared.activate()
        if pollTimer == nil {
            PageMessageDispatcher.shared.register(types: ["passwordFormSubmit", "passwordFieldsPresent"]) { [weak self] type, request, requestId, tab in
                self?.handlePageMessage(type: type, request: request, requestId: requestId, tab: tab)
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
    }

    private func poll() {
        for controller in WindowManager.shared.windowControllers {
            updateKeyButton(for: controller)
        }
    }

    private func handlePageMessage(type: String, request: String, requestId: Int64, tab: Tab) {
        guard let data = request.data(using: .utf8) else {
            tab.respondToPageMessage(requestId: requestId, success: false, response: "")
            return
        }

        // Every branch acks immediately -- an unanswered cefQuery hangs the
        // page's promise forever, and none of this work needs to block that
        // ack on anything (Keychain access and popover display both happen
        // after, fire-and-forget from the page's perspective).
        tab.respondToPageMessage(requestId: requestId, success: true, response: "{}")

        switch type {
        case "passwordFormSubmit":
            guard let payload = try? JSONDecoder().decode(PasswordFormSubmitPayload.self, from: data) else { return }
            handleFormSubmit(payload, tab: tab)
        case "passwordFieldsPresent":
            guard let payload = try? JSONDecoder().decode(PasswordFieldsPresentPayload.self, from: data) else { return }
            passwordFieldPresence.setObject(NSNumber(value: payload.present), forKey: tab)
        default:
            break
        }
    }

    /// SECURITY: `payload.password` only ever flows into PasswordStore.save
    /// (a Keychain write) or is dropped -- never logged, never written to
    /// any plaintext file, never included in a notification/pasteboard.
    private func handleFormSubmit(_ payload: PasswordFormSubmitPayload, tab: Tab) {
        guard !payload.password.isEmpty else { return }
        let profileName = tab.profileName

        guard !PasswordNeverStoreManager.shared.store(forProfileId: tab.profileId).isNeverForSite(payload.origin) else {
            return
        }

        if let existing = PasswordStore.credential(profileName: profileName, origin: payload.origin),
           existing.username == payload.username, existing.password == payload.password {
            // Identical to what's already saved -- nothing new to ask about.
            return
        }

        // v1 only prompts if this tab is currently the window's visible
        // tab at the moment the page's submit fires -- a background tab's
        // credentials are still captured up through the check above (so a
        // *changed* password isn't silently missed if the user switches
        // back to this tab and submits again), but this particular
        // submission doesn't get a queued prompt of its own. Queuing a
        // prompt for a tab that isn't visible yet is deferred past v1 --
        // see docs/ai-tasks/password-manager-notes.md's Deviations.
        guard let controller = WindowManager.shared.windowControllers.first(where: { windowController in
            windowController.tabs.contains(where: { $0 === tab })
        }), controller.activeTab === tab,
        let window = controller.window,
        let contentView = window.contentView else {
            return
        }

        let anchor = anchorView(in: contentView)
        savePrompt.show(
            origin: payload.origin,
            anchorView: anchor,
            onSave: {
                PasswordStore.save(profileName: profileName, origin: payload.origin, username: payload.username, password: payload.password)
            },
            onNever: {
                PasswordNeverStoreManager.shared.store(forProfileId: tab.profileId).setNeverForSite(payload.origin)
            }
        )
    }

    /// A thin, invisible positioning view near the omnibox's on-screen
    /// location, cached per window content view -- NSPopover needs a real
    /// NSView to anchor to, and (see PasswordManagerCoordinator's own class
    /// doc comment on why BrowserWindowController is off-limits) there's no
    /// reference to the real omnibox view available here the way
    /// BrowserWindowController's own PermissionPromptController gets one.
    /// Approximate rather than exact -- see docs/ai-tasks/
    /// password-manager-notes.md's Deviations for the honest caveat.
    private func anchorView(in contentView: NSView) -> NSView {
        if let existing = anchorViews.object(forKey: contentView) {
            existing.frame = Self.anchorFrame(in: contentView)
            return existing
        }
        let anchor = NSView(frame: Self.anchorFrame(in: contentView))
        anchor.autoresizingMask = [.minYMargin, .width]
        contentView.addSubview(anchor)
        anchorViews.setObject(anchor, forKey: contentView)
        return anchor
    }

    private static func anchorFrame(in contentView: NSView) -> NSRect {
        NSRect(
            x: contentView.bounds.width / 2 - 150,
            y: contentView.bounds.height - contentTopInset,
            width: 300,
            height: 1
        )
    }

    // MARK: - Autofill key icon

    /// Shows/hides this window's key icon based on its *current* active
    /// tab -- re-evaluated every poll tick (0.5s), so switching tabs or
    /// navigating to a different page updates the icon within one tick,
    /// same latency ReaderModeController accepts for its own Reader button
    /// (see that class's doc comment on why polling is the right call here
    /// with BrowserWindowController off-limits).
    private func updateKeyButton(for controller: BrowserWindowController) {
        guard let window = controller.window, let contentView = window.contentView else { return }
        guard let tab = controller.activeTab,
              passwordFieldPresence.object(forKey: tab)?.boolValue == true,
              let host = URL(string: tab.urlString)?.host,
              PasswordStore.credential(profileName: tab.profileName, origin: host) != nil
        else {
            setKeyButtonVisible(false, in: contentView, window: window)
            return
        }
        setKeyButtonVisible(true, in: contentView, window: window)
    }

    private func setKeyButtonVisible(_ visible: Bool, in contentView: NSView, window: NSWindow) {
        let button: NSButton
        if let existing = keyButtons.object(forKey: contentView) {
            button = existing
        } else {
            guard visible else { return }
            let size = Self.keyButtonSize
            button = NSButton(
                image: NSImage(systemSymbolName: "key.fill", accessibilityDescription: "Autofill Password")!,
                target: self, action: #selector(keyIconTapped(_:))
            )
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            // Offset further from the edge than ReaderModeController's own
            // floating button (which sits at width - size - 12) so the two
            // don't overlap on a page that happens to be both readerable
            // and have a saved login (rare, but not impossible -- an
            // article site with a comments login form, say).
            button.frame = NSRect(
                x: contentView.bounds.width - size * 2 - 24,
                y: contentView.bounds.height - Self.contentTopInset + (36 - size) / 2,
                width: size,
                height: size
            )
            button.autoresizingMask = [.minXMargin, .minYMargin]
            contentView.addSubview(button)
            keyButtons.setObject(button, forKey: contentView)
        }
        windowForKeyButton.setObject(window, forKey: button)
        button.isHidden = !visible
    }

    /// The only place a saved credential is ever filled into a page --
    /// exclusively in direct response to this explicit click, never
    /// automatically (see AutofillScript's own doc comment for why).
    /// Re-derives the active tab from the button's owning window at click
    /// time rather than using a captured reference, so a tab switch between
    /// the icon appearing and this click can't fill the wrong page.
    @objc private func keyIconTapped(_ sender: NSButton) {
        guard let window = windowForKeyButton.object(forKey: sender),
              let controller = window.windowController as? BrowserWindowController,
              let tab = controller.activeTab,
              let host = URL(string: tab.urlString)?.host,
              let credential = PasswordStore.credential(profileName: tab.profileName, origin: host)
        else {
            return
        }
        tab.executeJavaScript(AutofillScript.fillScript(username: credential.username, password: credential.password))
    }
}
