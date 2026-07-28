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
final class PaymentAddressAutofillCoordinator: NSObject {
    static let shared = PaymentAddressAutofillCoordinator()

    private var pollTimer: Timer?
    private let savePrompt = SaveAutofillPromptController()

    /// Which group ("card"/"address") the active tab's page currently has
    /// a recognized field focused in, if any -- updated directly by the
    /// autofillFieldFocused/autofillFieldBlurred messages (event-driven,
    /// unlike the password key icon's own "does a credential exist"
    /// check, which has to be polled since navigation alone can change it
    /// with no message of its own). Still re-read on every poll tick
    /// rather than immediately on the message itself, because switching
    /// *native* tabs doesn't fire a DOM blur event in the tab being left
    /// (there's no real DOM focus change, just an app-level UI selection),
    /// so the icon still needs a periodic "is this even the active tab
    /// anymore" reconciliation the same way the password icon does.
    private var focusedGroup = NSMapTable<Tab, NSString>.weakToStrongObjects()

    private var fillButtons = NSMapTable<NSView, NSButton>.weakToWeakObjects()
    private var windowForFillButton = NSMapTable<NSButton, NSWindow>.weakToWeakObjects()
    private var anchorViews = NSMapTable<NSView, NSView>.weakToWeakObjects()

    private static let contentTopInset: CGFloat = 32 + 36
    private static let fillButtonSize: CGFloat = 26

    private override init() {}

    /// Idempotent -- called from BrowserWindow.swift's init, matching
    /// PasswordManagerCoordinator/PageMessageDispatcher's own activation.
    func activate() {
        PageMessageDispatcher.shared.activate()
        if pollTimer == nil {
            PageMessageDispatcher.shared.register(
                types: ["autofillFieldFocused", "autofillFieldBlurred", "paymentFormSubmit", "addressFormSubmit"]
            ) { [weak self] type, request, requestId, tab in
                self?.handlePageMessage(type: type, request: request, requestId: requestId, tab: tab)
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.poll()
            }
        }
    }

    private func poll() {
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
        case "autofillFieldBlurred":
            focusedGroup.removeObject(forKey: tab)
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
        let alreadySaved = CardStore.allCards(profileName: profileName).contains { $0.last4 == last4 }
        guard !alreadySaved else { return }

        guard let expiry = Self.splitExpiry(month: payload.expMonth, year: payload.expYear, combined: payload.expCombined),
              let controller = activeTabController(for: tab), let anchor = anchor(for: controller)
        else {
            return
        }

        savePrompt.show(message: "Save this card ending \(last4)?", anchorView: anchor) {
            CardStore.save(
                profileName: profileName, cardholderName: payload.cardholderName,
                cardNumber: digitsOnly, expMonth: expiry.month, expYear: expiry.year
            )
        }
    }

    private func handleAddressSubmit(_ payload: AddressFormSubmitPayload, tab: Tab) {
        guard !payload.streetAddress.isEmpty || !payload.postalCode.isEmpty else { return }
        let profileName = tab.profileName
        let store = AddressStoreManager.shared.store(forProfileName: profileName)

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

        savePrompt.show(message: "Save this address?", anchorView: anchor) {
            store.save(candidate)
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

    private func activeTabController(for tab: Tab) -> BrowserWindowController? {
        // Same v1 simplification as the password manager's own save
        // prompt: only shown if this tab is currently the window's visible
        // one at submit time -- see PasswordManagerCoordinator.
        // handleFormSubmit's own doc comment for why.
        WindowManager.shared.windowControllers.first { $0.tabs.contains(where: { $0 === tab }) && $0.activeTab === tab }
    }

    private func anchor(for controller: BrowserWindowController) -> NSView? {
        guard let window = controller.window, let contentView = window.contentView else { return nil }
        return anchorView(in: contentView)
    }

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
        NSRect(x: contentView.bounds.width / 2 - 150, y: contentView.bounds.height - contentTopInset, width: 300, height: 1)
    }

    // MARK: - Fill icon

    private func updateFillButton(for controller: BrowserWindowController) {
        guard let window = controller.window, let contentView = window.contentView else { return }
        guard let tab = controller.activeTab, let group = focusedGroup.object(forKey: tab) as String? else {
            setFillButtonVisible(false, in: contentView, window: window, group: nil)
            return
        }
        let hasSaved = group == "card"
            ? !CardStore.allCards(profileName: tab.profileName).isEmpty
            : !AddressStoreManager.shared.store(forProfileName: tab.profileName).all().isEmpty
        setFillButtonVisible(hasSaved, in: contentView, window: window, group: group)
    }

    private func setFillButtonVisible(_ visible: Bool, in contentView: NSView, window: NSWindow, group: String?) {
        let button: NSButton
        if let existing = fillButtons.object(forKey: contentView) {
            button = existing
        } else {
            guard visible else { return }
            let size = Self.fillButtonSize
            button = NSButton(
                image: NSImage(systemSymbolName: "creditcard", accessibilityDescription: "Autofill")!,
                target: self, action: #selector(fillIconTapped(_:))
            )
            button.isBordered = false
            button.contentTintColor = .secondaryLabelColor
            // Third icon slot from the right, after Reader's (width - size
            // - 12) and the password manager's key icon (width - size*2 -
            // 24) -- see PasswordManagerCoordinator's own doc comment on
            // that spacing.
            button.frame = NSRect(
                x: contentView.bounds.width - size * 3 - 36,
                y: contentView.bounds.height - Self.contentTopInset + (36 - size) / 2,
                width: size,
                height: size
            )
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
            for card in CardStore.allCards(profileName: tab.profileName) {
                let item = NSMenuItem(
                    title: "\(card.cardholderName) ····\(card.last4)",
                    action: #selector(fillCard(_:)), keyEquivalent: ""
                )
                item.target = self
                item.representedObject = (tab, card.id)
                menu.addItem(item)
            }
        } else {
            for address in AddressStoreManager.shared.store(forProfileName: tab.profileName).all() {
                let title = [address.fullName, address.streetAddress, address.city].filter { !$0.isEmpty }.joined(separator: ", ")
                let item = NSMenuItem(title: title.isEmpty ? "Saved address" : title, action: #selector(fillAddress(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = (tab, address.id)
                menu.addItem(item)
            }
        }
        guard menu.items.count > 0 else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.midX, y: 0), in: sender)
    }

    @objc private func fillCard(_ sender: NSMenuItem) {
        guard let (tab, cardId) = sender.representedObject as? (Tab, String),
              let number = CardStore.cardNumber(profileName: tab.profileName, id: cardId),
              let summary = CardStore.allCards(profileName: tab.profileName).first(where: { $0.id == cardId })
        else {
            return
        }
        tab.executeJavaScript(AutofillFillScript.fillCardScript(
            cardholderName: summary.cardholderName, cardNumber: number,
            expMonth: String(format: "%02d", summary.expMonth), expYear: String(summary.expYear),
            combinedExpiry: String(format: "%02d/%02d", summary.expMonth, summary.expYear % 100)
        ))
    }

    @objc private func fillAddress(_ sender: NSMenuItem) {
        guard let (tab, addressId) = sender.representedObject as? (Tab, String),
              let address = AddressStoreManager.shared.store(forProfileName: tab.profileName).all().first(where: { $0.id == addressId })
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
