import AppKit

private struct PageMessageTypeEnvelope: Decodable { let type: String }

/// App-wide singleton that wires every tab's generic page-message channel
/// (Tab.onPageMessage) to native code, and dispatches each incoming message
/// by its `"type"` field to whichever feature registered for it.
///
/// Why this needs to be centralized: `Tab.onPageMessage` is a single
/// closure slot (see Tab.swift's own doc comment on why it's a closure
/// rather than a TabDelegate method) -- exactly one thing may set it per
/// tab. The password manager (browser-ojh.1) originally set it directly
/// itself, which worked while it was the only consumer; now that
/// card/address autofill (browser-ojh.2) also needs raw page messages, a
/// second independent wirer of the same closure would silently break one
/// feature's message delivery. This dispatcher is the one thing that ever
/// calls `tab.onPageMessage = ...`; PasswordManagerCoordinator,
/// PaymentAddressAutofillCoordinator, WebPushCoordinator and
/// StartPageSettingsCoordinator all register with it instead.
///
/// Wiring happens on TabLifecycleEvent.opened (browser-g6d) -- i.e. between
/// a Tab being constructed and its engine-side browser being created, so
/// there is no window at all in which a page can send a message that lands
/// on an unwired tab. This used to be a 0.5s discovery poll, and a message
/// sent before the next tick was dropped in complete silence: nothing
/// answers the cefQuery, so neither onSuccess nor onFailure runs in the
/// page. PasswordDetectionScript's retry-until-acked `sendReliable`
/// (browser-ojh.4) was written for exactly that race and is now redundant
/// rather than load-bearing -- it's kept as belt and braces, since it costs
/// nothing once the first attempt is always acked.
final class PageMessageDispatcher: TabLifecycleObserver {
    static let shared = PageMessageDispatcher()

    private var isActivated = false
    private var wiredTabs = NSHashTable<Tab>.weakObjects()
    private var handlers: [String: (_ type: String, _ request: String, _ requestId: Int64, _ tab: Tab) -> Void] = [:]

    private init() {}

    /// Idempotent -- called from BrowserWindow.swift's init (and from
    /// CEFEngineAdapter's own initialize(), earlier still), so the first
    /// window created in the process registers this with no separate
    /// explicit call site needed anywhere else.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
        TabLifecycleCenter.shared.addObserver(self)
        // Catch-up sweep for any tab that already existed when this first
        // ran. Empty in practice -- every activate() call site above runs
        // before that window's first tab is created -- but this is the one
        // class where "wired a moment too late" means silently swallowed
        // page messages, so it doesn't rely on that ordering holding
        // forever.
        for controller in WindowManager.shared.windowControllers {
            for tab in controller.tabs {
                wire(tab)
            }
        }
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        guard case .opened = event else { return }
        wire(tab)
    }

    private func wire(_ tab: Tab) {
        guard !wiredTabs.contains(tab) else { return }
        wiredTabs.add(tab)
        tab.onPageMessage = { [weak self, weak tab] request, requestId in
            guard let self, let tab else { return }
            self.dispatch(request, requestId: requestId, tab: tab)
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
