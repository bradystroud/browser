import AppKit
import UserNotifications

/// App-wide singleton bridging the Web Push / Notifications API
/// (browser-7jz.3) to macOS's real UNUserNotificationCenter.
///
/// Registers with PageMessageDispatcher for its own three page-message
/// types rather than touching Tab.onPageMessage directly or adding a
/// second CEF-level message channel -- see PageMessageDispatcher's own
/// doc comment for why that class exists at all: three features already
/// collided over that one closure slot before it did.
///
/// See NotificationOverrideScript's own doc comment for the full design.
/// The short version: permission is never reimplemented here. The
/// injected script's `Notification.requestPermission()` delegates
/// straight to the real, underlying Notification API, so this app's
/// existing CefPermissionHandler -> PermissionPromptController ->
/// PermissionStore path (browser-12m.2) is the only thing that ever
/// decides whether a page may show a notification at all -- this
/// coordinator only ever runs once a page's own constructor has already
/// resolved "granted", and its only job is turning that into a real
/// system notification and reporting back what happens to it (shown,
/// clicked, or dismissed).
///
/// Private windows: permission for a private window's "private"
/// pseudo-profile flows through the exact same CefPermissionHandler path,
/// just never persisted (see BrowserWindowController's isPrivate guard on
/// that path) -- so a private window can still be granted notifications
/// for the life of that window, and forgets the decision entirely once
/// it closes, with no extra code needed here. This coordinator itself
/// keeps no notification history of its own anywhere (`pending` below is
/// purely in-memory bookkeeping for in-flight notifications, not a log),
/// so "never persisted" holds for both real and private windows equally.
final class WebPushCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WebPushCoordinator()

    /// One entry per notification currently posted or awaiting its
    /// "notificationWaitForEvent" query, keyed by the UNNotificationRequest
    /// identifier this coordinator generated. `waitRequestId`/`resolvedEvent`
    /// exist to handle either arrival order: the page's second cefQuery
    /// (registering interest in the eventual click/dismiss) and the actual
    /// user interaction can race, however unlikely in practice given the
    /// short IPC round trip between them. Removed once resolved either way.
    private struct PendingNotification {
        weak var tab: Tab?
        var waitRequestId: Int64?
        var resolvedEvent: String?
    }

    private var pending: [String: PendingNotification] = [:]
    private var started = false

    private override init() {
        super.init()
    }

    /// Idempotent -- call once at launch (see CEFEngineAdapter.swift,
    /// alongside ContentBlockerCoordinator/ThreatListCoordinator's own
    /// `.start()` calls).
    func activate() {
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = self
        PageMessageDispatcher.shared.activate()
        PageMessageDispatcher.shared.register(
            types: ["notificationShow", "notificationWaitForEvent", "notificationClose"]
        ) { [weak self] type, request, requestId, tab in
            self?.handle(type: type, request: request, requestId: requestId, tab: tab)
        }
    }

    private struct ShowPayload: Decodable {
        let title: String
        let body: String?
        let icon: String?
        let tag: String?
    }
    private struct IdPayload: Decodable {
        let id: String
    }

    private func handle(type: String, request: String, requestId: Int64, tab: Tab) {
        guard let data = request.data(using: .utf8) else {
            tab.respondToPageMessage(requestId: requestId, success: false, response: "")
            return
        }
        switch type {
        case "notificationShow":
            guard let payload = try? JSONDecoder().decode(ShowPayload.self, from: data) else {
                tab.respondToPageMessage(requestId: requestId, success: false, response: "")
                return
            }
            postNotification(payload, tab: tab, requestId: requestId)

        case "notificationWaitForEvent":
            guard let payload = try? JSONDecoder().decode(IdPayload.self, from: data) else {
                tab.respondToPageMessage(requestId: requestId, success: false, response: "")
                return
            }
            guard var entry = pending[payload.id] else {
                // No matching post -- e.g. a stale/bogus id. Fail rather
                // than leave the page's promise hanging forever.
                tab.respondToPageMessage(requestId: requestId, success: false, response: "")
                return
            }
            if let resolvedEvent = entry.resolvedEvent {
                // The click/dismiss already happened before this query
                // arrived -- resolve immediately instead of waiting.
                tab.respondToPageMessage(requestId: requestId, success: true, response: "{\"event\":\"\(resolvedEvent)\"}")
                pending.removeValue(forKey: payload.id)
            } else {
                entry.waitRequestId = requestId
                pending[payload.id] = entry
                // Deliberately does NOT ack now -- left pending until
                // userNotificationCenter(_:didReceive:...) resolves it.
            }

        case "notificationClose":
            guard let payload = try? JSONDecoder().decode(IdPayload.self, from: data) else {
                tab.respondToPageMessage(requestId: requestId, success: false, response: "")
                return
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [payload.id])
            resolvePending(id: payload.id, event: "close")
            tab.respondToPageMessage(requestId: requestId, success: true, response: "{}")

        default:
            break
        }
    }

    private func postNotification(_ payload: ShowPayload, tab: Tab, requestId: Int64) {
        let id = UUID().uuidString
        // Seeded before any async work starts, so a click/dismiss that
        // (implausibly) races ahead of the page's own follow-up
        // "notificationWaitForEvent" query still has a tab to resolve
        // against -- see PendingNotification's own doc comment.
        pending[id] = PendingNotification(tab: tab, waitRequestId: nil, resolvedEvent: nil)

        let content = UNMutableNotificationContent()
        content.title = payload.title
        if let body = payload.body, !body.isEmpty {
            content.body = body
        }
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        // Authorization is a one-time, app-wide macOS gate, independent of
        // (and layered underneath) the per-origin web permission already
        // checked before this method is ever called -- lazy rather than
        // requested at launch, so a user who never visits a
        // notification-requesting site is never asked at all.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            guard granted else {
                DispatchQueue.main.async {
                    self?.pending.removeValue(forKey: id)
                    tab.respondToPageMessage(requestId: requestId, success: false, response: "")
                }
                return
            }
            UNUserNotificationCenter.current().add(request) { error in
                DispatchQueue.main.async {
                    guard error == nil else {
                        self?.pending.removeValue(forKey: id)
                        tab.respondToPageMessage(requestId: requestId, success: false, response: "")
                        return
                    }
                    tab.respondToPageMessage(requestId: requestId, success: true, response: "{\"id\":\"\(id)\"}")
                }
            }
        }
    }

    private func resolvePending(id: String, event: String) {
        guard var entry = pending[id] else { return }
        if let requestId = entry.waitRequestId, let tab = entry.tab {
            tab.respondToPageMessage(requestId: requestId, success: true, response: "{\"event\":\"\(event)\"}")
            pending.removeValue(forKey: id)
        } else {
            entry.resolvedEvent = event
            pending[id] = entry
        }
    }

    /// Brings the tab that showed a clicked notification to the front --
    /// its window (if not already key) and its own tab strip position.
    /// Reads WindowManager/BrowserWindowController's existing public
    /// `windowControllers`/`tabs`/`selectTab(at:)` surface only; adds
    /// nothing to either file.
    private func focusTab(_ tab: Tab) {
        for controller in WindowManager.shared.windowControllers {
            if let index = controller.tabs.firstIndex(where: { $0 === tab }) {
                NSApp.activate(ignoringOtherApps: true)
                controller.window?.makeKeyAndOrderFront(nil)
                controller.selectTab(at: index)
                return
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Without this, UNUserNotificationCenter suppresses a notification
    /// outright while this app is the foreground/active app -- but a page
    /// showing a notification while its own tab is frontmost (e.g. a chat
    /// app's "new message" alert) is exactly the common case, so this
    /// always presents it, matching every mainstream browser's behavior.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let event = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "click" : "close"
        if event == "click", let tab = pending[id]?.tab {
            focusTab(tab)
        }
        resolvePending(id: id, event: event)
        completionHandler()
    }
}
