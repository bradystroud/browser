import AppKit

private struct PageMessageTypeEnvelope: Decodable { let type: String }

/// App-wide singleton owning the one poll loop that wires every tab's
/// generic page-message channel (Tab.onPageMessage) to native code, and
/// dispatches each incoming message by its `"type"` field to whichever
/// feature registered for it.
///
/// Why this needs to be centralized: `Tab.onPageMessage` is a single
/// closure slot (see Tab.swift's own doc comment on why -- TabDelegate is
/// implemented by the off-limits BrowserWindowController, so this is a
/// plain closure instead) -- exactly one thing may set it per tab. The
/// password manager (browser-ojh.1) originally set it directly itself,
/// which worked while it was the only consumer; now that card/address
/// autofill (browser-ojh.2) also needs raw page messages, a second
/// independent poller wiring the same closure would silently race with the
/// first and randomly break one feature's message delivery depending on
/// which poller's tick ran last. This dispatcher is the one thing that
/// ever calls `tab.onPageMessage = ...`; PasswordManagerCoordinator and
/// PaymentAddressAutofillCoordinator both register with it instead of
/// polling/wiring tabs themselves.
final class PageMessageDispatcher {
    static let shared = PageMessageDispatcher()

    private var pollTimer: Timer?
    private var wiredTabs = NSHashTable<Tab>.weakObjects()
    private var handlers: [String: (_ type: String, _ request: String, _ requestId: Int64, _ tab: Tab) -> Void] = [:]

    private init() {}

    /// Idempotent -- called from BrowserWindow.swift's init, matching
    /// every other per-feature poller in this app (ReaderModeController,
    /// the password manager) for the same reason: Tab instances are only
    /// ever constructed in the off-limits BrowserWindowController, so
    /// there's no push notification for "a new tab exists" available
    /// without touching it.
    func activate() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Registers `handler` for one or more page-message `"type"` values.
    /// Each type may have at most one handler -- a second registration for
    /// a type that's already taken would mean two features silently
    /// fighting over the same message, which is always a bug, never
    /// intended, so it's asserted against in debug builds.
    func register(types: [String], handler: @escaping (_ type: String, _ request: String, _ requestId: Int64, _ tab: Tab) -> Void) {
        for type in types {
            assert(handlers[type] == nil, "PageMessageDispatcher: a handler for \"\(type)\" is already registered")
            handlers[type] = handler
        }
    }

    private func poll() {
        for controller in WindowManager.shared.windowControllers {
            for tab in controller.tabs where !wiredTabs.contains(tab) {
                wiredTabs.add(tab)
                tab.onPageMessage = { [weak self, weak tab] request, requestId in
                    guard let self, let tab else { return }
                    self.dispatch(request, requestId: requestId, tab: tab)
                }
            }
        }
    }

    private func dispatch(_ request: String, requestId: Int64, tab: Tab) {
        guard let data = request.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(PageMessageTypeEnvelope.self, from: data),
              let handler = handlers[envelope.type]
        else {
            // Unrecognized type, or not even valid JSON -- still ack (with
            // failure) so the page's promise doesn't hang forever; no
            // registered feature gets a chance to answer this one since
            // none claimed its type.
            tab.respondToPageMessage(requestId: requestId, success: false, response: "")
            return
        }
        handler(envelope.type, request, requestId, tab)
    }
}
