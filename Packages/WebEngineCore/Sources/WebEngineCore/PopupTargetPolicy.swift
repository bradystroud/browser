import Foundation

/// Which URLs a page may put into a new top-level tab or window, whether by
/// `window.open`, a `target="_blank"` link or a modifier-click.
///
/// A new tab is loaded by the browser, not by the page, and the engines'
/// own renderer-side refusals (Chromium's block on top-level `data:`
/// navigations, say) do not apply to a browser-initiated load. So the page
/// may only name a destination it could have reached by ordinary
/// navigation: http(s), a blank page, or a blob it created itself.
/// `data:`, `file:`, `javascript:` and every other scheme are refused.
///
/// The CEF bridge carries a C++ copy of this rule
/// (`BRWPopupTargetAllowed` in BRWClientHandler.mm) because it decides on
/// CEF's UI thread without calling into Swift; the two are kept in step by
/// hand.
public enum PopupTargetPolicy {
    /// `openerFrameURL` is the URL of the frame that asked for the popup.
    public static func isAllowed(targetURL: String, openerFrameURL: String) -> Bool {
        isAllowed(targetURL: targetURL, openerOrigin: WebOrigin(urlString: openerFrameURL))
    }

    public static func isAllowed(targetURL: String, openerOrigin: WebOrigin?) -> Bool {
        let trimmed = targetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // `window.open()` with no URL: a blank page.
        if trimmed.isEmpty { return true }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        switch trimmed[..<colon].lowercased() {
        case "http", "https":
            return WebOrigin(urlString: trimmed) != nil
        case "about":
            return trimmed.lowercased() == "about:blank"
        case "blob":
            guard let openerOrigin, let blobOrigin = WebOrigin(urlString: trimmed) else { return false }
            return blobOrigin == openerOrigin
        default:
            return false
        }
    }
}
