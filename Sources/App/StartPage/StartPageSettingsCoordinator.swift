import Foundation

/// Registers with PageMessageDispatcher for the start page gear button's
/// "openStartPageSettings" page message (see StartPageRenderer's gear
/// anchor), opening Settings straight to its Start Page tab.
///
/// This used to be handled by intercepting a same-document URL-fragment
/// navigation the gear's plain `<a href="#browser-settings">` link produced
/// in Tab.engineTabDidChangeURL -- a fragile side channel that turned out
/// not to reliably fire at all (the gear silently did nothing when clicked).
/// A real page message through the same cefQuery-backed channel every other
/// page->native signal in this app already uses (password detection, card/
/// address autofill) is the robust fix: no dependency on exactly how/
/// whether CEF's display handler reports a same-document fragment change.
final class StartPageSettingsCoordinator {
    static let shared = StartPageSettingsCoordinator()

    private var isRegistered = false

    private init() {}

    /// Idempotent -- same pattern as PasswordManagerCoordinator.activate()/
    /// PaymentAddressAutofillCoordinator.activate(), called from
    /// BrowserWindow.swift's init so the first window created in the
    /// process wires this up, with no separate explicit call site needed.
    func activate() {
        PageMessageDispatcher.shared.activate()
        guard !isRegistered else { return }
        isRegistered = true
        PageMessageDispatcher.shared.register(types: ["openStartPageSettings"]) { [weak self] _, _, requestId, tab in
            self?.handleOpenStartPageSettings(requestId: requestId, tab: tab)
        }
    }

    private func handleOpenStartPageSettings(requestId: Int64, tab: Tab) {
        // No payload to decode, and nothing meaningful to report back --
        // ack immediately so the page's promise doesn't hang, matching
        // every other page-message handler's own convention.
        tab.respondToPageMessage(requestId: requestId, success: true, response: "{}")
        SettingsWindowController.shared.showStartPageTab()
    }
}
