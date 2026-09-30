import WebKit

/// Maps BackgroundTabPolicy onto WKPreferences.inactiveSchedulingPolicy
/// (public, macOS 14+). An inactive web view is one that is not visible --
/// here, every tab but the selected one, since a hidden tab's view is
/// removed from the window. `.suspend` is WebKit's own default: the page's
/// process stops, macOS may then reclaim it under memory pressure, and the
/// tab reloads when shown again (WebKitTab.webViewWebContentProcessDidTerminate).
enum WebKitBackgroundTabPolicy {
    static var isAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    static var current: BackgroundTabPolicy = .balanced

    /// A WKWebView's WKPreferences object is shared with the configuration it
    /// was built from, so this also takes effect on a live tab.
    static func apply(to preferences: WKPreferences) {
        guard #available(macOS 14.0, *) else { return }
        switch current {
        case .saveMemory: preferences.inactiveSchedulingPolicy = .suspend
        case .balanced: preferences.inactiveSchedulingPolicy = .throttle
        case .keepReady: preferences.inactiveSchedulingPolicy = .none
        }
    }
}
