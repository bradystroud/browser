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
/// Entirely event-driven (browser-g6d). Everything the key icon's visibility
/// and the automatic fill depend on now has a signal of its own:
///
/// - the page's password fields appearing/disappearing -> the
///   "passwordFieldsPresent" page message,
/// - the tab navigating (including a same-document SPA navigation) ->
///   TabLifecycleEvent.navigated, which is also what decides a pending
///   credential is a login attempt (flushPendingCredentialIfNavigated),
/// - the window's visible tab changing -> TabLifecycleEvent.becameActive,
/// - a saved credential existing for the current origin -> a background
///   Keychain lookup landing in `credentialCache`, or PasswordStore posting
///   .passwordStoreDidChange.
///
/// The last of those is why refresh() is called from the lookup completion
/// as well: cachedCredential(profileName:host:) deliberately answers "not
/// yet" rather than blocking, and with the old 0.5s poll gone there is no
/// later tick to pick the real answer up on.
final class PasswordManagerCoordinator: NSObject, TabLifecycleObserver {
    static let shared = PasswordManagerCoordinator()

    private var isActivated = false
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

    /// The credential each tab has typed but not yet visibly submitted, held
    /// until that tab navigates -- the signal that stands in for a submit
    /// event on pages that never fire one (see
    /// flushPendingCredentialIfNavigated).
    private var pendingCredentials = NSMapTable<Tab, PendingCredential>.weakToStrongObjects()

    /// The URL each tab was last automatically filled at, so a page is filled
    /// once rather than on every event that re-runs autofillIfNeeded. Keyed
    /// by URL rather than a plain flag so navigating to a second login page
    /// in the same tab fills again.
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
    /// live at 120+ seconds). Every main-thread caller reads only this
    /// cache, so the worst case is a key icon that appears one Keychain
    /// round-trip late.
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
        guard !isActivated else { return }
        isActivated = true
        PageMessageDispatcher.shared.activate()
        PageMessageDispatcher.shared.register(
            types: ["passwordFormSubmit", "passwordFieldsPresent", "passwordCredentialCandidate"]
        ) { [weak self] type, request, requestId, tab in
            self?.handlePageMessage(type: type, request: request, requestId: requestId, tab: tab)
        }
        NotificationCenter.default.addObserver(
            forName: .passwordStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.credentialCache.removeAll()
            // Saving/deleting a credential changes whether the key icon
            // should be showing for whatever is on screen right now.
            self?.refresh()
        }
        TabLifecycleCenter.shared.addObserver(self)
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        switch event {
        case .navigated:
            // A tab holding a typed-but-unsubmitted credential that has since
            // navigated was, as far as anything outside the page can tell, a
            // login attempt -- this is the trigger the 0.5s poll used to
            // approximate by re-reading every tab's urlString.
            flushPendingCredentialIfNavigated(tab)
            // The new page will report its own field presence via
            // PasswordDetectionScript's document-start injection, which is
            // what actually drives the fill; this just clears/keeps the icon
            // honest in the meantime.
            updateKeyButton(for: controller)
        case .becameActive:
            updateKeyButton(for: controller)
        case .opened, .finishedLoading, .closed:
            break
        }
    }

    /// Re-evaluates everything that depends on state this coordinator can't
    /// be pushed about per-tab -- a Keychain lookup landing, or the store
    /// changing underneath. Autofill is re-tried for *every* tab, not just
    /// each window's visible one: a background tab that finished loading a
    /// login page before its credential lookup came back still deserves to
    /// be filled by the time the user switches to it.
    private func refresh() {
        for controller in WindowManager.shared.windowControllers {
            for tab in controller.tabs {
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
    /// lookup the first time one is asked for. Returns nil while that lookup
    /// is still outstanding -- and calls refresh() when it lands, since with
    /// the old 0.5s poll gone (browser-g6d) there's no later tick for callers
    /// to pick the real answer up on.
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
                // Only when the answer is a real credential: a "no credential
                // here" result can't make any icon appear or any page fill,
                // and refreshing on it would re-enter this method for every
                // other unresolved host on every miss.
                if found != nil {
                    self.refresh()
                }
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
            // The other half of what the 0.5s poll used to do: this message
            // is the one that says a page has somewhere to fill into, so
            // both the fill and the icon are decided here rather than on a
            // later tick.
            autofillIfNeeded(tab)
            if let controller = controller(for: tab) {
                updateKeyButton(for: controller)
            }
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
    ///
    /// Turning the preference on mid-session only takes effect from the next
    /// event that re-runs this (a navigation, a tab switch, the page's next
    /// presence report) rather than "within 0.5s" as it did while this was
    /// poll-driven -- PasswordAutofillPreference posts no change
    /// notification to hook, and an already-loaded page the user is looking
    /// at still has the key icon as its manual path.
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

    /// The window `tab` currently belongs to, if any -- a page message can
    /// arrive from a tab in any window, and from a background tab whose
    /// window isn't key.
    private func controller(for tab: Tab) -> BrowserWindowController? {
        WindowManager.shared.windowControllers.first { $0.tabs.contains { $0 === tab } }
    }

    /// Shows/hides this window's key icon based on its *current* active tab.
    /// Called from every event that can change the answer -- see this
    /// class's own doc comment for that list.
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
        // Cached (whatever made this icon visible already warmed it) --
        // and never a blocking Keychain call on the main thread regardless,
        // per browser-le4.1.
        guard let credential = cachedCredential(profileName: tab.profileName, host: host) else { return }
        tab.executeJavaScript(AutofillScript.fillScript(username: credential.username, password: credential.password))
    }
}
