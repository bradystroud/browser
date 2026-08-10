import AppKit

private struct PasswordFormSubmitPayload: Decodable {
    let origin: String
    let username: String
    let password: String
}

private struct PasswordFieldsPresentPayload: Decodable {
    let present: Bool
}

/// A credential the user has typed into a page but that hasn't produced a
/// recognizable login attempt yet. Held per tab until either the page
/// reports a submit-like gesture or the tab navigates away from
/// `capturedAtURL` -- see PasswordDetectionScript's own doc comment on why
/// "the tab navigated" has to be a trigger at all (plenty of real login
/// pages never fire a submit event).
private final class PendingCredential {
    let origin: String
    let username: String
    let password: String
    let capturedAtURL: String

    init(origin: String, username: String, password: String, capturedAtURL: String) {
        self.origin = origin
        self.username = username
        self.password = password
        self.capturedAtURL = capturedAtURL
    }
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

    /// The credential each tab has typed but not yet visibly submitted, and
    /// the URL each tab was last seen at, so the poll can spot "this tab
    /// navigated while holding a pending credential" -- the signal that
    /// stands in for a submit event on pages that never fire one.
    private var pendingCredentials = NSMapTable<Tab, PendingCredential>.weakToStrongObjects()
    private var lastKnownURL = NSMapTable<Tab, NSString>.weakToStrongObjects()

    /// The URL each tab was last automatically filled at, so a single page
    /// is filled once rather than every 0.5s tick. Keyed by URL rather than
    /// a plain flag so navigating to a second login page in the same tab
    /// fills again.
    private var autofilledURL = NSMapTable<Tab, NSString>.weakToStrongObjects()

    /// Recently-prompted credential keys, to collapse the duplicate reports
    /// a single login gesture can legitimately produce (Enter in a password
    /// field usually fires the script's keydown handler *and* a real submit
    /// event milliseconds later). Time-based rather than permanent so a user
    /// who dismisses a prompt with "Not Now" and submits again still gets
    /// asked the second time.
    private var recentlyPromptedAt: [String: Date] = [:]
    private static let duplicatePromptWindow: TimeInterval = 3

    /// Cached Keychain lookups, keyed "profileName\\0host". `nil` value means
    /// "looked up, no credential" -- distinct from absent, which means "not
    /// looked up yet".
    ///
    /// Every Keychain read happens on `keychainQueue`, never the main
    /// thread: a credential saved under a different code-signing identity
    /// makes SecItemCopyMatching block on a real, modal SecurityAgent
    /// confirmation dialog, which on the main thread is a hard UI freeze for
    /// as long as the dialog goes unanswered (browser-le4.1 -- reproduced
    /// live at 120+ seconds). The poll below reads only this cache, so the
    /// worst case is now a key icon that appears a tick late.
    private var credentialCache: [String: (username: String, password: String)?] = [:]
    private var credentialLookupsInFlight: Set<String> = []
    private let keychainQueue = DispatchQueue(label: "dev.stroud.browser.password-keychain")

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
            PageMessageDispatcher.shared.register(
                types: ["passwordFormSubmit", "passwordFieldsPresent", "passwordCredentialCandidate"]
            ) { [weak self] type, request, requestId, tab in
                self?.handlePageMessage(type: type, request: request, requestId: requestId, tab: tab)
            }
            NotificationCenter.default.addObserver(
                forName: .passwordStoreDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                self?.credentialCache.removeAll()
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
    }

    private func poll() {
        for controller in WindowManager.shared.windowControllers {
            for tab in controller.tabs {
                flushPendingCredentialIfNavigated(tab)
                autofillIfNeeded(tab)
            }
            updateKeyButton(for: controller)
        }
    }

    // MARK: - Keychain lookups (never on the main thread)

    private func cacheKey(profileName: String, host: String) -> String {
        "\(profileName)\u{0}\(host)"
    }

    /// The cached credential for this profile/host, kicking off a background
    /// lookup the first time one is asked for. Returns nil while that
    /// lookup is still outstanding -- callers are all poll-driven, so they
    /// simply pick the answer up on a later tick.
    private func cachedCredential(profileName: String, host: String) -> (username: String, password: String)? {
        let key = cacheKey(profileName: profileName, host: host)
        if let cached = credentialCache[key] {
            return cached
        }
        guard !credentialLookupsInFlight.contains(key) else { return nil }
        credentialLookupsInFlight.insert(key)
        keychainQueue.async { [weak self] in
            let found = PasswordStore.credential(profileName: profileName, origin: host)
            DispatchQueue.main.async {
                guard let self else { return }
                self.credentialCache[key] = found
                self.credentialLookupsInFlight.remove(key)
            }
        }
        return nil
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
            // A recognizable login gesture -- this supersedes whatever the
            // tab was holding, so the navigation path below can't ask a
            // second time about the same credential.
            pendingCredentials.removeObject(forKey: tab)
            maybePrompt(origin: payload.origin, username: payload.username, password: payload.password, tab: tab)
        case "passwordCredentialCandidate":
            guard let payload = try? JSONDecoder().decode(PasswordFormSubmitPayload.self, from: data),
                  !payload.password.isEmpty else { return }
            pendingCredentials.setObject(
                PendingCredential(
                    origin: payload.origin,
                    username: payload.username,
                    password: payload.password,
                    capturedAtURL: tab.urlString
                ),
                forKey: tab
            )
        case "passwordFieldsPresent":
            guard let payload = try? JSONDecoder().decode(PasswordFieldsPresentPayload.self, from: data) else { return }
            passwordFieldPresence.setObject(NSNumber(value: payload.present), forKey: tab)
        default:
            break
        }
    }

    /// The other half of the "sites that never fire a submit event" fix (see
    /// PasswordDetectionScript's doc comment): a tab holding a typed-but-
    /// unsubmitted credential that has since navigated somewhere else was,
    /// as far as anyone can tell from outside the page, a login attempt.
    private func flushPendingCredentialIfNavigated(_ tab: Tab) {
        let current = tab.urlString
        defer { lastKnownURL.setObject(current as NSString, forKey: tab) }
        guard let pending = pendingCredentials.object(forKey: tab), pending.capturedAtURL != current else {
            return
        }
        pendingCredentials.removeObject(forKey: tab)
        maybePrompt(origin: pending.origin, username: pending.username, password: pending.password, tab: tab)
    }

    /// SECURITY: `password` only ever flows into PasswordStore.save (a
    /// Keychain write) or is dropped -- never logged, never written to any
    /// plaintext file, never included in a notification/pasteboard.
    private func maybePrompt(origin: String, username: String, password: String, tab: Tab) {
        guard !password.isEmpty else { return }
        let profileName = tab.profileName

        // One login gesture can legitimately report itself twice (Enter in a
        // password field fires the script's keydown handler and then a real
        // submit event); collapse those into a single prompt.
        let key = "\(profileName)\u{0}\(origin)\u{0}\(username)\u{0}\(password)"
        if let promptedAt = recentlyPromptedAt[key], Date().timeIntervalSince(promptedAt) < Self.duplicatePromptWindow {
            return
        }

        guard !PasswordNeverStoreManager.shared.store(forProfileId: tab.profileId).isNeverForSite(origin) else {
            return
        }

        // Only prompts if this tab is the window's visible tab right now --
        // a background tab's credentials are still captured (so a *changed*
        // password isn't silently missed once the user returns to that tab),
        // but this particular attempt doesn't get a queued prompt of its
        // own. See docs/ai-tasks/password-manager-notes.md's Deviations.
        guard let controller = WindowManager.shared.windowControllers.first(where: { windowController in
            windowController.tabs.contains(where: { $0 === tab })
        }), controller.activeTab === tab,
        let window = controller.window,
        let contentView = window.contentView else {
            return
        }

        // The "is this already saved?" check is a Keychain read, so it has
        // to happen off the main thread (browser-le4.1) -- hence deciding
        // and showing asynchronously rather than inline.
        keychainQueue.async { [weak self] in
            let existing = PasswordStore.credential(profileName: profileName, origin: origin)
            DispatchQueue.main.async {
                guard let self else { return }
                if let existing, existing.username == username, existing.password == password {
                    // Identical to what's already saved -- nothing to ask about.
                    // (Also the normal outcome right after an automatic fill.)
                    return
                }
                guard controller.activeTab === tab else { return }
                self.recentlyPromptedAt[key] = Date()
                let anchor = self.anchorView(in: contentView, controller: controller)
                self.savePrompt.show(
                    origin: origin,
                    anchorView: anchor,
                    onSave: {
                        self.keychainQueue.async {
                            PasswordStore.save(profileName: profileName, origin: origin, username: username, password: password)
                        }
                    },
                    onNever: {
                        PasswordNeverStoreManager.shared.store(forProfileId: tab.profileId).setNeverForSite(origin)
                    }
                )
            }
        }
    }

    // MARK: - Automatic fill

    /// Fills a saved credential into a matching page once per navigation,
    /// when PasswordAutofillPreference allows it (on by default -- see that
    /// enum's doc comment for the security trade-off this reverses from v1
    /// and why). The key icon remains the manual path, both for when the
    /// preference is off and for re-filling a page the user has since
    /// cleared.
    private func autofillIfNeeded(_ tab: Tab) {
        guard PasswordAutofillPreference.isAutomaticFillEnabled,
              passwordFieldPresence.object(forKey: tab)?.boolValue == true
        else { return }
        let url = tab.urlString
        guard (autofilledURL.object(forKey: tab) as String?) != url,
              let host = URL(string: url)?.host,
              let credential = cachedCredential(profileName: tab.profileName, host: host)
        else { return }
        autofilledURL.setObject(url as NSString, forKey: tab)
        tab.executeJavaScript(AutofillScript.fillScript(username: credential.username, password: credential.password))
    }

    /// A thin, invisible positioning view near the omnibox's on-screen
    /// location, cached per window content view -- NSPopover needs a real
    /// NSView to anchor to, and (see PasswordManagerCoordinator's own class
    /// doc comment on why BrowserWindowController is off-limits) there's no
    /// reference to the real omnibox view available here the way
    /// BrowserWindowController's own PermissionPromptController gets one.
    /// Approximate rather than exact -- see docs/ai-tasks/
    /// password-manager-notes.md's Deviations for the honest caveat.
    private func anchorView(in contentView: NSView, controller: BrowserWindowController) -> NSView {
        if let existing = anchorViews.object(forKey: contentView) {
            existing.frame = Self.anchorFrame(in: contentView, controller: controller)
            return existing
        }
        let anchor = NSView(frame: Self.anchorFrame(in: contentView, controller: controller))
        anchor.autoresizingMask = [.minYMargin, .width]
        contentView.addSubview(anchor)
        anchorViews.setObject(anchor, forKey: contentView)
        return anchor
    }

    private static func anchorFrame(in contentView: NSView, controller: BrowserWindowController) -> NSRect {
        NSRect(
            x: contentView.bounds.width / 2 - 150,
            y: controller.contentAreaTopY,
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
              cachedCredential(profileName: tab.profileName, host: host) != nil
        else {
            setKeyButtonVisible(false, in: contentView, window: window, controller: controller)
            return
        }
        setKeyButtonVisible(true, in: contentView, window: window, controller: controller)
    }

    private func setKeyButtonVisible(_ visible: Bool, in contentView: NSView, window: NSWindow, controller: BrowserWindowController) {
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
            // article site with a comments login form, say). Vertically
            // centered within the toolbar row itself, not hanging into the
            // content area or the tab strip -- see
            // BrowserWindowController.toolbarRowHeight's own doc comment
            // and ReaderModeController.setButtonVisible's matching comment
            // for why (content area is covered by CEF's own compositing
            // regardless of AppKit z-order; the tab strip is exactly where
            // this button was reported overlapping the mute/close buttons).
            let toolbarHeight = controller.toolbarRowHeight
            button.frame = NSRect(
                x: contentView.bounds.width - size * 2 - 24,
                y: contentView.bounds.height - (toolbarHeight + size) / 2,
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
              let host = URL(string: tab.urlString)?.host
        else {
            return
        }
        // Cached (the poll that made this icon visible already warmed it) --
        // and never a blocking Keychain call on the main thread regardless,
        // per browser-le4.1.
        guard let credential = cachedCredential(profileName: tab.profileName, host: host) else { return }
        tab.executeJavaScript(AutofillScript.fillScript(username: credential.username, password: credential.password))
    }
}
