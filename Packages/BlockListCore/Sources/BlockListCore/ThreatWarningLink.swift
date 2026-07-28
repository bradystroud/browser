import Foundation

/// Encodes/decodes the warning interstitial's "Continue anyway (unsafe)"
/// link (browser-12m.6). Clicking it is a real top-level navigation
/// attempt to a fake `.invalid` host carrying the real, originally-blocked
/// URL as a query parameter -- CEF's own `OnBeforeResourceLoad` (the same
/// place every other request already goes through) recognizes and
/// intercepts exactly this host+path before it would otherwise try to look
/// it up, records a session-scoped bypass for the real URL's host, and
/// re-issues the original navigation. This needs no new JS-to-native
/// message channel: a plain `<a href>` click is already something the
/// bridge sees.
///
/// The bridge has its own C++ counterpart to the decode half of this
/// (`BRWThreatListParseContinueMarker` in `Sources/Bridge/
/// BRWThreatListInternal.h`) -- it can't call into this Swift code from
/// CEF's IO thread, so the exact same host/path/query-key literals are
/// kept in sync by convention (documented in both places) rather than a
/// shared header, the same way `"private"` is a magic profile-name string
/// shared by convention between `BRWBrowser.mm` and
/// `ContentBlockerCoordinator.swift` elsewhere in this app.
public enum ThreatWarningLink {
    /// `.invalid` is IANA-reserved (RFC 2606) specifically for domain names
    /// that are never meant to resolve -- an honest signal (to anyone
    /// reading a page's source, or a network log) that this was never a
    /// real destination, only ever intercepted locally.
    public static let magicHost = "browser-safety-warning.invalid"
    public static let continuePath = "/continue-unsafe"

    /// The href for the interstitial's "Continue anyway" link, embedding
    /// `originalURL` (the navigation that was blocked) so the bridge can
    /// re-issue it once the bypass is recorded.
    public static func continueURL(bypassing originalURL: String) -> String {
        let encoded = originalURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? originalURL
        return "https://\(magicHost)\(continuePath)?url=\(encoded)"
    }

    /// The reverse of `continueURL(bypassing:)` -- nil if `url` isn't
    /// exactly this app's own marker link. Exists so this encode/decode
    /// pair can be tested as a genuine round trip; the bridge's own C++
    /// parser is the one actually exercised at runtime (see this type's own
    /// doc comment for why).
    public static func originalURL(fromContinueLink url: String) -> String? {
        let prefix = "https://\(magicHost)\(continuePath)?url="
        guard url.hasPrefix(prefix) else { return nil }
        let encoded = String(url.dropFirst(prefix.count))
        return encoded.removingPercentEncoding
    }
}
