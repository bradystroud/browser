import AppKit

/// What EmailFieldDetectionScript reports about the focused field. There is
/// deliberately no origin or URL in it: where the page is comes from the
/// engine (PageMessage.origin, Tab.urlString), never from the page.
private struct EmailFieldPayload: Decodable {
    let value: String?
    let x: Double?
    let y: Double?
    let width: Double?
    let height: Double?
    let viewportWidth: Double?
    let viewportHeight: Double?
    let hasPasswordField: Bool?
}

/// The field a tab's page has focused, as of its last report.
private final class FocusedEmailField {
    let origin: WebOrigin
    var value: String
    /// Viewport CSS pixels.
    var rect: CGRect
    var viewportWidth: Double
    let hasPasswordField: Bool
    /// Me-card emails, fetched once per focus off the main thread. Never
    /// stored beyond this focus.
    var meCardEmails: [String] = []

    init(origin: WebOrigin, value: String, rect: CGRect, viewportWidth: Double, hasPasswordField: Bool) {
        self.origin = origin
        self.value = value
        self.rect = rect
        self.viewportWidth = viewportWidth
        self.hasPasswordField = hasPasswordField
    }
}

/// An address typed into an email field but not seen submitted yet -- the
/// same "the tab navigated, so that was a submit" reasoning as
/// PasswordManagerCoordinator's PendingCredential.
private final class PendingEmail {
    let email: String
    let capturedAtURL: String

    init(email: String, capturedAtURL: String) {
        self.email = email
        self.capturedAtURL = capturedAtURL
    }
}

/// Email-address suggestions under a focused email field, on either engine.
///
/// Sources, per profile: the profile's own addresses (Settings), saved
/// addresses' emails, saved-password usernames that are emails, learned
/// uses, rule addresses, and the Contacts "Me" card's emails -- the last
/// only when Contacts access is already granted and "Fill from my contact
/// card" is on; this never asks for access. EmailSuggestionRanker orders
/// them against the engine's verified URL for the tab.
///
/// A private window reads the first profile's data, never learns, and never
/// creates anything on disk for its throwaway profile.
///
/// Coordination with the password manager: when the field's form has a
/// password field and the password manager holds a credential for this
/// origin, the popup stays closed -- the password manager fills that form.
final class EmailAutofillCoordinator: NSObject, TabLifecycleObserver {
    static let shared = EmailAutofillCoordinator()

    private static let maximumSuggestions = 5

    private var isActivated = false
    private let popup = EmailSuggestionPopup()
    private var focused = NSMapTable<Tab, FocusedEmailField>.weakToStrongObjects()
    private var pending = NSMapTable<Tab, PendingEmail>.weakToStrongObjects()
    /// The tab whose field the popup is currently showing for.
    private weak var popupTab: Tab?
    /// Set by Esc; cleared by the next focus or keystroke in the field.
    private var dismissedTab: Tab?

    /// Saved-password usernames that are emails, per profile name (the
    /// password store's key). Keychain reads never happen on the main thread
    /// (see PasswordManagerCoordinator.credentialCache for why).
    private var passwordUsernames: [String: [String]] = [:]
    private var passwordLookupsInFlight: Set<String> = []
    private let keychainQueue = DispatchQueue(label: "dev.stroud.browser.email-autofill-keychain")
    private let contactsQueue = DispatchQueue(label: "dev.stroud.browser.email-autofill-contacts")

    private override init() {}

    func activate() {
        guard !isActivated else { return }
        isActivated = true
        PageMessageDispatcher.shared.activate()
        PageMessageDispatcher.shared.register(
            types: ["emailFieldFocused", "emailFieldInput", "emailFieldBlurred", "emailFieldSubmitted"]
        ) { [weak self] (message: PageMessage) in
            self?.handle(message)
        }
        TabLifecycleCenter.shared.addObserver(self)
        NotificationCenter.default.addObserver(forName: .passwordStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.passwordUsernames.removeAll()
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let window = note.object as? NSWindow, let tab = self.popupTab,
                  self.controller(for: tab)?.window === window else { return }
            self.hidePopup()
        }
        popup.onChoose = { [weak self] row in self?.choose(row) }
        popup.onDismissByUser = { [weak self] in
            self?.dismissedTab = self?.popupTab
            self?.popupTab = nil
        }
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        switch event {
        case .navigated:
            flushPendingIfNavigated(tab)
            focused.removeObject(forKey: tab)
            if popupTab === tab { hidePopup() }
        case .becameActive:
            if let shown = popupTab, shown !== tab, controller.tabs.contains(where: { $0 === shown }) { hidePopup() }
        case .closed:
            focused.removeObject(forKey: tab)
            pending.removeObject(forKey: tab)
            if popupTab === tab { hidePopup() }
        case .opened, .finishedLoading:
            break
        }
    }

    // MARK: - Page messages

    private func handle(_ message: PageMessage) {
        let tab = message.tab
        tab.respondToPageMessage(requestId: message.requestId, success: true, response: "{}")
        guard let origin = message.origin, let data = message.request.data(using: .utf8),
              let payload = try? JSONDecoder().decode(EmailFieldPayload.self, from: data)
        else { return }
        let value = payload.value ?? ""

        switch message.type {
        case "emailFieldFocused":
            let field = FocusedEmailField(
                origin: origin, value: value, rect: Self.rect(payload),
                viewportWidth: payload.viewportWidth ?? 0, hasPasswordField: payload.hasPasswordField ?? false
            )
            focused.setObject(field, forKey: tab)
            dismissedTab = nil
            // Counts and reasons only: the addresses themselves stay out of the log.
            let rows = suggestionRows(for: tab, field: field)
            NSLog("Browser: email field focused (%@, password form: %@): %ld suggestion(s), top: %@",
                  origin.serialized, field.hasPasswordField ? "yes" : "no", rows.count, rows.first?.detail ?? "none")
            loadMeCardEmails(for: field, tab: tab)
            update(tab)
        case "emailFieldInput":
            guard let field = focused.object(forKey: tab), field.origin == origin else { return }
            if field.value != value, dismissedTab === tab { dismissedTab = nil }
            field.value = value
            field.rect = Self.rect(payload)
            field.viewportWidth = payload.viewportWidth ?? field.viewportWidth
            update(tab)
        case "emailFieldBlurred":
            focused.removeObject(forKey: tab)
            if popupTab === tab { hidePopup() }
            if let email = EmailAddress.normalized(value) {
                pending.setObject(PendingEmail(email: email, capturedAtURL: tab.urlString), forKey: tab)
            }
        case "emailFieldSubmitted":
            pending.removeObject(forKey: tab)
            learn(value, tab: tab, pageURL: tab.urlString)
        default:
            break
        }
    }

    private static func rect(_ payload: EmailFieldPayload) -> CGRect {
        CGRect(x: payload.x ?? 0, y: payload.y ?? 0, width: payload.width ?? 0, height: payload.height ?? 0)
    }

    // MARK: - Learning

    private func flushPendingIfNavigated(_ tab: Tab) {
        guard let entry = pending.object(forKey: tab), entry.capturedAtURL != tab.urlString else { return }
        pending.removeObject(forKey: tab)
        learn(entry.email, tab: tab, pageURL: entry.capturedAtURL)
    }

    /// `pageURL` is always a Tab.urlString -- the engine's committed URL at
    /// the time the address was typed -- never a page-reported one.
    private func learn(_ raw: String, tab: Tab, pageURL: String) {
        guard !tab.isPrivate, EmailAutofillPreferences.suggestEmailAddresses,
              WebOrigin(urlString: pageURL) != nil,
              EmailAutofillStoreManager.store(forProfileId: tab.profileId).recordUse(email: raw, pageURL: pageURL)
        else { return }
        NSLog("Browser: learned an email address use on %@", URLComponents(string: pageURL)?.host ?? "?")
        NotificationCenter.default.post(name: EmailAutofillStoreManager.didChangeNotification, object: nil)
    }

    // MARK: - Sources

    /// Which profile's data a tab's suggestions read. A private window has
    /// nothing of its own, so it borrows the first profile's, read-only.
    private func sourceProfile(for tab: Tab) -> (id: String, name: String)? {
        guard tab.isPrivate else { return (tab.profileId, tab.profileName) }
        return ProfileManager.shared.profiles.first.map { ($0.id, $0.name) }
    }

    private func candidates(for tab: Tab, field: FocusedEmailField) -> (emails: [String], sources: [String: String]) {
        var emails: [String] = []
        var sources: [String: String] = [:]
        func add(_ raw: String, _ source: String) {
            guard let email = EmailAddress.normalized(raw) else { return }
            if sources[email] == nil { sources[email] = source; emails.append(email) }
        }
        field.meCardEmails.forEach { add($0, "My Card") }
        if let profile = sourceProfile(for: tab) {
            let store = EmailAutofillStoreManager.store(forProfileId: profile.id)
            store.data.addresses.forEach { add($0, "Your address") }
            AddressStoreManager.shared.store(forProfileId: profile.id).all().forEach { add($0.email, "Saved address") }
            cachedPasswordUsernames(profileName: profile.name).forEach { add($0, "Saved password") }
        }
        return (emails, sources)
    }

    private func usageAndRules(for tab: Tab) -> ([EmailUsageRecord], [EmailRule]) {
        guard let profile = sourceProfile(for: tab) else { return ([], []) }
        let data = EmailAutofillStoreManager.store(forProfileId: profile.id).data
        return (data.usage, data.rules)
    }

    private func cachedPasswordUsernames(profileName: String) -> [String] {
        if let cached = passwordUsernames[profileName] { return cached }
        guard !passwordLookupsInFlight.contains(profileName) else { return [] }
        passwordLookupsInFlight.insert(profileName)
        keychainQueue.async { [weak self] in
            let usernames = PasswordStore.allCredentials(profileName: profileName)
                .compactMap { EmailAddress.normalized($0.username) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.passwordUsernames[profileName] = usernames
                self.passwordLookupsInFlight.remove(profileName)
                if !usernames.isEmpty, let tab = self.popupTab ?? self.activeFocusedTab() { self.update(tab) }
            }
        }
        return []
    }

    private func loadMeCardEmails(for field: FocusedEmailField, tab: Tab) {
        guard EmailAutofillPreferences.fillFromMeCard, ContactsAutofillSource.isAuthorized else { return }
        contactsQueue.async { [weak self, weak field, weak tab] in
            let emails = ContactsAutofillSource.meCard()?.emails.map(\.value) ?? []
            DispatchQueue.main.async {
                guard let self, let field, let tab, !emails.isEmpty,
                      self.focused.object(forKey: tab) === field else { return }
                field.meCardEmails = emails
                self.update(tab)
            }
        }
    }

    // MARK: - Popup

    private func controller(for tab: Tab) -> BrowserWindowController? {
        WindowManager.shared.windowControllers.first { $0.tabs.contains { $0 === tab } }
    }

    private func activeFocusedTab() -> Tab? {
        WindowManager.shared.windowControllers.lazy.compactMap(\.activeTab).first { self.focused.object(forKey: $0) != nil }
    }

    private func update(_ tab: Tab) {
        guard EmailAutofillPreferences.suggestEmailAddresses,
              let field = focused.object(forKey: tab),
              dismissedTab !== tab,
              let controller = controller(for: tab), controller.activeTab === tab,
              let window = controller.window,
              // The popup is ordered on screen only while the page itself
              // has keyboard focus: ordering a window in while the omnibox
              // is focused crashes AppKit (see AGENTS.md).
              let responder = window.firstResponder as? NSView, responder.isDescendant(of: tab.hostView),
              // The same origin the engine says the tab is showing now.
              WebOrigin(urlString: tab.urlString) == field.origin
        else {
            if popupTab === tab || popupTab == nil { hidePopup() }
            return
        }
        if field.hasPasswordField, PasswordManagerCoordinator.shared.offersSavedCredential(in: tab) {
            hidePopup()
            return
        }

        let rows = suggestionRows(for: tab, field: field)
        // Nothing to add once the field already holds the only match.
        if rows.count == 1, rows[0].email == field.value.trimmingCharacters(in: .whitespaces).lowercased() {
            hidePopup()
            return
        }
        guard let fieldRect = screenRect(of: field, in: tab, window: window) else {
            hidePopup()
            return
        }
        popupTab = tab
        popup.show(rows: rows, below: fieldRect, in: window, focusContainer: tab.hostView)
    }

    private func suggestionRows(for tab: Tab, field: FocusedEmailField) -> [EmailSuggestionRow] {
        let (emails, sources) = candidates(for: tab, field: field)
        let (usage, rules) = usageAndRules(for: tab)
        let ranked = EmailSuggestionRanker.rank(
            candidates: emails, usage: usage, rules: rules, pageURL: tab.urlString,
            prefix: field.value, limit: Self.maximumSuggestions
        )
        let provider = IdentityProviderHints.parse(urlString: tab.urlString).provider
        return ranked.enumerated().map { index, item in
            let reason = index == 0 ? item.reason.label(provider: provider) : nil
            return EmailSuggestionRow(email: item.email, detail: reason ?? sources[item.email] ?? "Used before")
        }
    }

    /// Maps the field's viewport box to screen coordinates through the view
    /// the engine draws the page into. The box is page-reported, so it is
    /// only ever used for placement, and is clamped to the page view.
    private func screenRect(of field: FocusedEmailField, in tab: Tab, window: NSWindow) -> NSRect? {
        let pageView = tab.devTools.pageView.subviews.first ?? tab.devTools.pageView
        guard pageView.window === window, pageView.bounds.width > 0, field.viewportWidth > 0 else { return nil }
        let scale = pageView.bounds.width / field.viewportWidth
        let bounds = pageView.bounds
        let left = min(max(field.rect.minX * scale, 0), bounds.width)
        let width = min(max(field.rect.width * scale, 0), bounds.width - left)
        let topFromTop = min(max(field.rect.minY * scale, 0), bounds.height)
        let bottomFromTop = min(max(field.rect.maxY * scale, 0), bounds.height)
        guard bottomFromTop > 0, topFromTop < bounds.height else { return nil }
        let rectInView: NSRect
        if pageView.isFlipped {
            rectInView = NSRect(x: left, y: topFromTop, width: width, height: bottomFromTop - topFromTop)
        } else {
            rectInView = NSRect(x: left, y: bounds.height - bottomFromTop, width: width, height: bottomFromTop - topFromTop)
        }
        return window.convertToScreen(pageView.convert(rectInView, to: nil))
    }

    private func hidePopup() {
        popupTab = nil
        popup.dismiss()
    }

    private func choose(_ row: EmailSuggestionRow) {
        guard let tab = popupTab, let field = focused.object(forKey: tab),
              WebOrigin(urlString: tab.urlString) == field.origin
        else {
            hidePopup()
            return
        }
        field.value = row.email
        hidePopup()
        tab.executeJavaScript(EmailFieldDetectionScript.fillScript(email: row.email, expectedOrigin: field.origin))
    }
}
