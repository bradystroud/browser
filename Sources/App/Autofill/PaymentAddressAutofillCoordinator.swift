import AppKit

private struct PaymentFormSubmitPayload: Decodable {
    let origin: String
    let cardNumber: String
    let cardholderName: String
    let expMonth: String
    let expYear: String
    let expCombined: String
}

private struct AddressFormSubmitPayload: Decodable {
    let fullName: String
    let streetAddress: String
    let addressLine2: String
    let city: String
    let state: String
    let postalCode: String
    let country: String
    let phone: String
    let email: String
}

/// App-wide singleton for card & address autofill's native-side half
/// (browser-ojh.2) -- registers with PageMessageDispatcher (see that
/// class's own doc comment for why tab wiring is centralized there rather
/// than here) for PaymentAddressDetectionScript's four message types, and
/// owns the one floating fill-icon + one save-prompt popover shown at a
/// time across the whole app, same patterns PasswordManagerCoordinator
/// already established for the password manager.
///
/// Event-driven throughout (browser-g6d): the fill icon is re-evaluated when
/// a recognized field is focused/blurred, when the window's visible tab
/// changes or its page navigates (TabLifecycleEvent), and when a background
/// CardStore lookup lands. It used to be re-derived on a 0.5s poll, purely
/// because switching *native* tabs fires no DOM blur event in the tab being
/// left -- TabLifecycleEvent.becameActive is that missing signal.
final class PaymentAddressAutofillCoordinator: NSObject, TabLifecycleObserver {
    static let shared = PaymentAddressAutofillCoordinator()

    private var isActivated = false
    private let savePrompt = SaveAutofillPromptController()

    /// Which group ("card"/"address") each tab's page currently has a
    /// recognized field focused in, if any -- set by the
    /// autofillFieldFocused/autofillFieldBlurred messages, and cleared when
    /// the tab navigates (a brand-new document has nothing focused until it
    /// says otherwise).
    private var focusedGroup = NSMapTable<Tab, NSString>.weakToStrongObjects()

    private var fillButtons = NSMapTable<NSView, NSButton>.weakToWeakObjects()
    private var windowForFillButton = NSMapTable<NSButton, NSWindow>.weakToWeakObjects()
    private var anchorViews = NSMapTable<NSView, NSView>.weakToWeakObjects()

    /// Cached card summaries per profile name. Absent means "not looked up
    /// yet"; an empty array means "looked up, this profile has no cards."
    ///
    /// Every CardStore read happens on `keychainQueue`, never the main
    /// thread: a card saved under a different code-signing identity makes
    /// SecItemCopyMatching block on a modal SecurityAgent confirmation
    /// dialog, which on the main thread is a hard UI freeze for as long as
    /// that dialog goes unanswered (browser-le4.1 -- reproduced live at 120+
    /// seconds against PasswordStore, whose fix this mirrors; CardStore uses
    /// the identical no-explicit-ACL pattern). Every main-thread caller
    /// reads only this cache, so the worst case is a fill icon one Keychain
    /// round-trip late.
    private var cardSummariesCache: [String: [StoredCardSummary]] = [:]
    private var cardLookupsInFlight: Set<String> = []
    private let keychainQueue = DispatchQueue(label: "dev.stroud.browser.autofill-keychain")

    private override init() {}

    /// The cached card summaries for this profile, kicking off a background
    /// lookup the first time one is asked for. Returns an empty array while
    /// that lookup is outstanding, and refreshes the fill icon when it lands
    /// -- with the 0.5s poll gone (browser-g6d) there's no later tick for
    /// callers to pick the real answer up on.
    private func cachedCards(profileName: String) -> [StoredCardSummary] {
        if let cached = cardSummariesCache[profileName] {
            return cached
        }
        guard !cardLookupsInFlight.contains(profileName) else { return [] }
        cardLookupsInFlight.insert(profileName)
        keychainQueue.async { [weak self] in
            let cards = CardStore.allCards(profileName: profileName)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cardSummariesCache[profileName] = cards
                self.cardLookupsInFlight.remove(profileName)
                // Only when there's something to offer: an empty result can't
                // make the icon appear, and refreshing on it would re-enter
                // this method for every window on every miss.
                if !cards.isEmpty {
                    self.refresh()
                }
            }
        }
        return []
    }

    /// Idempotent -- called from BrowserWindow.swift's init, matching
    /// PasswordManagerCoordinator/PageMessageDispatcher's own activation.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        PageMessageDispatcher.shared.activate()
        PageMessageDispatcher.shared.register(
            types: ["autofillFieldFocused", "autofillFieldBlurred", "paymentFormSubmit", "addressFormSubmit"]
        ) { [weak self] type, request, requestId, tab in
            self?.handlePageMessage(type: type, request: request, requestId: requestId, tab: tab)
        }
        NotificationCenter.default.addObserver(
            forName: .cardStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.cardSummariesCache.removeAll()
            self?.refresh()
        }
        TabLifecycleCenter.shared.addObserver(self)
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        switch event {
        case .becameActive:
            // The signal the 0.5s poll existed for: switching native tabs
            // fires no DOM blur event in the tab being left, so nothing in
            // the page ever tells us the icon now belongs to a different
            // page's focus state.
            updateFillButton(for: controller)
        case .navigated:
            // A new document has nothing focused until its own freshly
            // injected script says so. (The poll never did this, so a stale
            // icon could survive a navigation until the next blur.)
            focusedGroup.removeObject(forKey: tab)
            updateFillButton(for: controller)
        case .opened, .finishedLoading, .closed:
            break
        }
    }

    private func refresh() {
        for controller in WindowManager.shared.windowControllers {
            updateFillButton(for: controller)
        }
    }

    private func handlePageMessage(type: String, request: String, requestId: Int64, tab: Tab) {
        guard let data = request.data(using: .utf8) else {
            tab.respondToPageMessage(requestId: requestId, success: false, response: "")
            return
        }
        // Every branch acks immediately, same reasoning as
        // PasswordManagerCoordinator's own handler -- an unanswered
        // cefQuery hangs the page's promise forever.
        tab.respondToPageMessage(requestId: requestId, success: true, response: "{}")

        switch type {
        case "autofillFieldFocused":
            guard let payload = try? JSONDecoder().decode([String: String].self, from: data), let group = payload["group"] else { return }
            focusedGroup.setObject(group as NSString, forKey: tab)
            updateFillButtonForWindow(of: tab)
        case "autofillFieldBlurred":
            focusedGroup.removeObject(forKey: tab)
            updateFillButtonForWindow(of: tab)
        case "paymentFormSubmit":
            guard let payload = try? JSONDecoder().decode(PaymentFormSubmitPayload.self, from: data) else { return }
            handlePaymentSubmit(payload, tab: tab)
        case "addressFormSubmit":
            guard let payload = try? JSONDecoder().decode(AddressFormSubmitPayload.self, from: data) else { return }
            handleAddressSubmit(payload, tab: tab)
        default:
            break
        }
    }

    /// SECURITY: `payload.cardNumber` only ever flows into CardStore.save
    /// (a Keychain write) or is dropped -- never logged, never written to
    /// any plaintext file. There is no CVC/CSC in this payload at all --
    /// PaymentAddressDetectionScript never reads one into any outgoing
    /// message in the first place (see that file's own doc comment).
    private func handlePaymentSubmit(_ payload: PaymentFormSubmitPayload, tab: Tab) {
        let digitsOnly = payload.cardNumber.filter(\.isNumber)
        guard digitsOnly.count >= 8 else { return }
        let profileName = tab.profileName

        // Skip if an existing card already has this last-4 -- a cheap
        // proxy that avoids needing a Touch-ID-gated full-number read just
        // to decide whether to prompt. Imprecise (two different real cards
        // could coincidentally share a last-4), but the failure mode is
        // just an occasional missed re-prompt for a genuinely different
        // card, never a wrongly-skipped save of a first-time one.
        let last4 = String(digitsOnly.suffix(4))

        // Resolved before the Keychain hop below, while still on the main
        // thread -- both are main-thread-only AppKit reads.
        guard let expiry = Self.splitExpiry(month: payload.expMonth, year: payload.expYear, combined: payload.expCombined),
              let controller = activeTabController(for: tab), let anchor = anchor(for: controller)
        else {
            return
        }

        // The "do we already have this card?" check is a Keychain read, so
        // it can't happen inline on the main thread (browser-le4.1) -- hence
        // deciding and showing asynchronously.
        keychainQueue.async { [weak self] in
            let alreadySaved = CardStore.allCards(profileName: profileName).contains { $0.last4 == last4 }
            DispatchQueue.main.async {
                guard let self, !alreadySaved, controller.activeTab === tab else { return }
                self.savePrompt.show(message: "Save this card ending \(last4)?", anchorView: anchor) {
                    self.keychainQueue.async {
                        CardStore.save(
                            profileName: profileName, cardholderName: payload.cardholderName,
                            cardNumber: digitsOnly, expMonth: expiry.month, expYear: expiry.year
                        )
                    }
                }
            }
        }
    }

    private func handleAddressSubmit(_ payload: AddressFormSubmitPayload, tab: Tab) {
        // A private window's profile is throwaway, so an address saved under
        // it would sit on disk where no window can ever show it again.
        guard !tab.isPrivate else { return }
        guard !payload.streetAddress.isEmpty || !payload.postalCode.isEmpty else { return }
        let store = AddressStoreManager.shared.store(forProfileId: tab.profileId)

        let candidate = StoredAddress(
            fullName: payload.fullName, streetAddress: payload.streetAddress, addressLine2: payload.addressLine2,
            city: payload.city, state: payload.state, postalCode: payload.postalCode, country: payload.country,
            phone: payload.phone, email: payload.email
        )
        // Skip if an address with the same street + postal code is already
        // saved -- a reasonable "is this the same one" proxy without
        // requiring every field to match exactly.
        let alreadySaved = store.all().contains { $0.streetAddress == candidate.streetAddress && $0.postalCode == candidate.postalCode }
        guard !alreadySaved else { return }

        guard let controller = activeTabController(for: tab), let anchor = anchor(for: controller) else { return }

        savePrompt.show(message: "Save this address?", anchorView: anchor) { [weak self] in
            store.save(candidate)
            // AddressStore has no change notification of its own (unlike
            // CardStore) and this window may still have an address field
            // focused, whose icon was hidden a moment ago precisely because
            // nothing was saved yet.
            self?.refresh()
        }
    }

    /// Splits whatever expiry information the page reported into a
    /// (month, 4-digit year) pair -- a form with separate month/year fields
    /// reports those directly (a bare 2-digit year is normalized to the
    /// 2000s, the only range realistic for a card being saved today); a
    /// form with one combined "MM/YY"-shaped field is parsed on a
    /// best-effort basis. Returns nil if nothing parses as valid numbers --
    /// there's no reliable general parser for every real-world expiry
    /// format a page might use, and CardStore.save requires real Ints.
    private static func splitExpiry(month: String, year: String, combined: String) -> (month: Int, year: Int)? {
        if let monthValue = Int(month), let yearValue = Int(year) {
            return (monthValue, normalizeYear(yearValue))
        }
        let digits = combined.filter(\.isNumber)
        guard digits.count == 4,
              let monthValue = Int(digits.prefix(2)), let yearValue = Int(digits.suffix(2))
        else {
            return nil
        }
        return (monthValue, normalizeYear(yearValue))
    }

    private static func normalizeYear(_ year: Int) -> Int {
        year < 100 ? 2000 + year : year
    }

    /// A page message can arrive from a tab in any window, including a
    /// background one -- updateFillButton(for:) then decides for itself
    /// whether that tab is the one on screen.
    private func updateFillButtonForWindow(of tab: Tab) {
        guard let controller = WindowManager.shared.windowControllers.first(where: { $0.tabs.contains { $0 === tab } }) else { return }
        updateFillButton(for: controller)
    }

    private func activeTabController(for tab: Tab) -> BrowserWindowController? {
        // Same v1 simplification as the password manager's own save
        // prompt: only shown if this tab is currently the window's visible
        // one at submit time -- see PasswordManagerCoordinator.
        // handleFormSubmit's own doc comment for why.
        WindowManager.shared.windowControllers.first { $0.tabs.contains(where: { $0 === tab }) && $0.activeTab === tab }
    }

    private func anchor(for controller: BrowserWindowController) -> NSView? {
        guard let window = controller.window, let contentView = window.contentView else { return nil }
        return anchorView(in: contentView, controller: controller)
    }

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
        NSRect(x: contentView.bounds.width / 2 - 150, y: controller.contentAreaTopY, width: 300, height: 1)
    }

    // MARK: - Fill icon

    private func updateFillButton(for controller: BrowserWindowController) {
        guard let window = controller.window, let contentView = window.contentView else { return }
        guard let tab = controller.activeTab, let group = focusedGroup.object(forKey: tab) as String? else {
            setFillButtonVisible(false, in: contentView, window: window, group: nil, controller: controller)
            return
        }
        let hasSaved = group == "card"
            ? !cachedCards(profileName: tab.profileName).isEmpty
            : !AddressStoreManager.shared.store(forProfileId: tab.profileId).all().isEmpty
        setFillButtonVisible(hasSaved, in: contentView, window: window, group: group, controller: controller)
    }

    private func setFillButtonVisible(_ visible: Bool, in contentView: NSView, window: NSWindow, group: String?, controller: BrowserWindowController) {
        let button: NSButton
        if let existing = fillButtons.object(forKey: contentView) {
            button = existing
        } else {
            guard visible else { return }
            button = NSButton(
                image: NSImage(systemSymbolName: "creditcard", accessibilityDescription: "Autofill")!,
                target: self, action: #selector(fillIconTapped(_:))
            )
            button.applyChromeAppearance(.glass)
            // Slot 3 leaves stable space for Reader, Downloads and password
            // autofill even when any of those optional controls is hidden.
            button.frame = controller.trailingToolbarControlFrame(slot: 3)
            button.autoresizingMask = [.minXMargin, .minYMargin]
            contentView.addSubview(button)
            fillButtons.setObject(button, forKey: contentView)
        }
        if let group {
            button.image = NSImage(systemSymbolName: group == "card" ? "creditcard" : "mappin.and.ellipse", accessibilityDescription: "Autofill")
        }
        windowForFillButton.setObject(window, forKey: button)
        button.isHidden = !visible
    }

    /// Shows a menu of saved cards/addresses matching whichever group is
    /// currently focused, so the user picks which one to fill -- unlike
    /// the password manager's single-credential-per-origin fill (chunk 3
    /// of browser-ojh.1), there can be several saved cards/addresses with
    /// no origin to disambiguate by, so this always asks rather than
    /// guessing which one to use. Re-derives the active tab/group from the
    /// button's owning window at click time, same reasoning as the
    /// password manager's own key-icon handler.
    @objc private func fillIconTapped(_ sender: NSButton) {
        guard let window = windowForFillButton.object(forKey: sender),
              let controller = window.windowController as? BrowserWindowController,
              let tab = controller.activeTab,
              let group = focusedGroup.object(forKey: tab) as String?
        else {
            return
        }

        let menu = NSMenu()
        if group == "card" {
            for card in cachedCards(profileName: tab.profileName) {
                let item = NSMenuItem(
                    title: "\(card.cardholderName) ····\(card.last4)",
                    action: #selector(fillCard(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = (tab, card.id)
                menu.addItem(item)
            }
        } else {
            for address in AddressStoreManager.shared.store(forProfileId: tab.profileId).all() {
                let title = [address.fullName, address.streetAddress, address.city].filter { !$0.isEmpty }.joined(separator: ", ")
                let item = NSMenuItem(title: title.isEmpty ? "Saved address" : title, action: #selector(fillAddress(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (tab, address.id)
                menu.addItem(item)
            }
            // Always offered for an address-group field, even with zero
            // saved addresses (browser-ojh.3) -- Contacts.app is a second,
            // independent fill source, not conditional on having already
            // saved something through this app first.
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            let contactsItem = NSMenuItem(title: "Fill from Contacts…", action: #selector(fillFromContactsTapped(_:)), keyEquivalent: "")
            contactsItem.target = self
            contactsItem.representedObject = (tab, sender)
            menu.addItem(contactsItem)
        }
        guard menu.items.count > 0 else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.midX, y: 0), in: sender)
    }

    /// Requests Contacts access (if not already determined), then shows a
    /// second menu listing the user's own contacts -- picking one fills the
    /// same recognized address form via AutofillFillScript.
    /// fillAddressScript, exactly like a saved address does. Never prompts
    /// for Contacts access a second time after a denial (see
    /// ContactsAutofillSource.requestAccessIfNeeded's own doc comment) --
    /// shows a one-time explanatory alert pointing at System Settings
    /// instead.
    @objc private func fillFromContactsTapped(_ sender: NSMenuItem) {
        guard let (tab, button) = sender.representedObject as? (Tab, NSButton) else { return }
        ContactsAutofillSource.requestAccessIfNeeded { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.showContactsAccessDeniedAlert()
                return
            }
            self.showContactsPicker(for: tab, anchoredTo: button)
        }
    }

    private func showContactsAccessDeniedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Contacts Access Needed"
        alert.informativeText = "To fill from Contacts, allow access in System Settings > Privacy & Security > Contacts."
        alert.runModal()
    }

    private func showContactsPicker(for tab: Tab, anchoredTo button: NSButton) {
        let candidates = ContactsAutofillSource.fetchCandidates()
        guard !candidates.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "No Contacts Found"
            alert.informativeText = "No contacts with a name, address, phone, or email were found."
            alert.runModal()
            return
        }
        let menu = NSMenu()
        for candidate in candidates {
            let item = NSMenuItem(title: candidate.displayName, action: #selector(fillFromContact(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (tab, candidate)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.midX, y: 0), in: button)
    }

    @objc private func fillFromContact(_ sender: NSMenuItem) {
        guard let (tab, candidate) = sender.representedObject as? (Tab, ContactFillCandidate) else { return }
        tab.executeJavaScript(AutofillFillScript.fillAddressScript(
            fullName: candidate.fullName, streetAddress: candidate.streetAddress, addressLine2: candidate.addressLine2,
            city: candidate.city, state: candidate.state, postalCode: candidate.postalCode, country: candidate.country,
            phone: candidate.phone, email: candidate.email
        ))
    }

    @objc private func fillCard(_ sender: NSMenuItem) {
        guard let (tab, cardId) = sender.representedObject as? (Tab, String),
              let summary = cachedCards(profileName: tab.profileName).first(where: { $0.id == cardId })
        else {
            return
        }
        // Reading the full number is a Keychain read, and a click is no
        // safer a place to block the main thread than a poll is
        // (browser-le4.1) -- so it hops off and back before touching the
        // page. SECURITY: `number` only ever flows into the fill script;
        // never logged, never written anywhere.
        let profileName = tab.profileName
        keychainQueue.async { [weak tab] in
            guard let number = CardStore.cardNumber(profileName: profileName, id: cardId) else { return }
            DispatchQueue.main.async {
                guard let tab else { return }
                tab.executeJavaScript(AutofillFillScript.fillCardScript(
                    cardholderName: summary.cardholderName, cardNumber: number,
                    expMonth: String(format: "%02d", summary.expMonth), expYear: String(summary.expYear),
                    combinedExpiry: String(format: "%02d/%02d", summary.expMonth, summary.expYear % 100)
                ))
            }
        }
    }

    @objc private func fillAddress(_ sender: NSMenuItem) {
        guard let (tab, addressId) = sender.representedObject as? (Tab, String),
              let address = AddressStoreManager.shared.store(forProfileId: tab.profileId).all().first(where: { $0.id == addressId })
        else {
            return
        }
        tab.executeJavaScript(AutofillFillScript.fillAddressScript(
            fullName: address.fullName, streetAddress: address.streetAddress, addressLine2: address.addressLine2,
            city: address.city, state: address.state, postalCode: address.postalCode, country: address.country,
            phone: address.phone, email: address.email
        ))
    }
}
