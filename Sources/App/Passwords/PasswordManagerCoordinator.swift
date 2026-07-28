import AppKit

private struct PageMessageTypeEnvelope: Decodable { let type: String }

private struct PasswordFormSubmitPayload: Decodable {
    let origin: String
    let username: String
    let password: String
}

/// App-wide singleton that wires every tab's generic page-message channel
/// (Tab.onPageMessage) to the password manager, and owns the one
/// save-password popover shown at a time across the whole app.
///
/// Why a polling singleton rather than wiring this at Tab creation: Tab
/// instances are only ever constructed in BrowserWindowController.swift
/// (`Tab(profileName:initialURL:)`), which stays off-limits for this task
/// (hot with concurrent Tab Groups/other work) -- so there's no push
/// notification for "a new tab was created" available without touching it.
/// Instead this polls `WindowManager.shared.windowControllers.flatMap { $0.tabs }`
/// every 0.5s and wires any tab it hasn't seen yet, tracked via a
/// weak-referencing NSHashTable so a closed tab's Tab object can still be
/// deallocated normally. Same reasoning ReaderModeController documents for
/// polling `activeTab` instead of getting a push notification -- see that
/// class's own doc comment.
///
/// Deliberately polls *every* tab, not just each window's activeTab: a
/// background tab's password form can still be submitted (e.g. a redirect
/// finishing while another tab has focus), and only wiring the active tab
/// would silently drop that page's cefQuery forever (CEF has no retry --
/// an un-answered query just hangs). Whether to actually *show* the save
/// prompt for a message from a currently-inactive tab is a separate
/// decision, made in handleFormSubmit(_:tab:) below -- v1 skips prompting
/// in that case rather than queuing (see that method's own doc comment).
final class PasswordManagerCoordinator {
    static let shared = PasswordManagerCoordinator()

    private var pollTimer: Timer?
    private var wiredTabs = NSHashTable<Tab>.weakObjects()
    private let savePrompt = SavePasswordPromptController()
    private var anchorViews = NSMapTable<NSView, NSView>.weakToWeakObjects()

    /// Matches FindBarController/ReaderModeController's hardcoded
    /// tab-strip (32) + toolbar (36) height constant -- see
    /// FindBarController.contentTopInset's doc comment for why this is
    /// duplicated rather than shared across files.
    private static let contentTopInset: CGFloat = 32 + 36

    private init() {}

    /// Idempotent -- called from BrowserWindow.swift's init (see that
    /// file's own doc comments for why new per-feature wiring lives there
    /// rather than in BrowserWindowController/AppDelegate), so the first
    /// browser window created in the process starts this ticking, with no
    /// separate explicit call site needed anywhere else.
    func activate() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        for controller in WindowManager.shared.windowControllers {
            for tab in controller.tabs where !wiredTabs.contains(tab) {
                wiredTabs.add(tab)
                tab.onPageMessage = { [weak self, weak tab] request, requestId in
                    guard let self, let tab else { return }
                    self.handlePageMessage(request, requestId: requestId, tab: tab)
                }
            }
        }
    }

    private func handlePageMessage(_ request: String, requestId: Int64, tab: Tab) {
        guard let data = request.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PageMessageTypeEnvelope.self, from: data)
        else {
            tab.respondToPageMessage(requestId: requestId, success: false, response: "")
            return
        }

        // Every branch acks immediately -- an unanswered cefQuery hangs the
        // page's promise forever, and none of this work needs to block that
        // ack on anything (Keychain access and popover display both happen
        // after, fire-and-forget from the page's perspective).
        tab.respondToPageMessage(requestId: requestId, success: true, response: "{}")

        switch envelope.type {
        case "passwordFormSubmit":
            guard let payload = try? JSONDecoder().decode(PasswordFormSubmitPayload.self, from: data) else { return }
            handleFormSubmit(payload, tab: tab)
        case "passwordFieldsPresent":
            // Chunk 4 (the omnibox key icon) is this message's consumer --
            // nothing to do with it yet.
            break
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

        guard !PasswordNeverStoreManager.shared.store(forProfileName: profileName).isNeverForSite(payload.origin) else {
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
                PasswordNeverStoreManager.shared.store(forProfileName: profileName).setNeverForSite(payload.origin)
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
}
