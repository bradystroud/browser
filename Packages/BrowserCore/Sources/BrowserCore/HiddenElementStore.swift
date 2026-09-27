import Foundation

/// One element the user took off a site with the element hider.
public struct HiddenElement: Codable, Equatable, Sendable {
    public let selector: String
    /// What the element was, in words ("Navigation", "Accept cookies"), so
    /// the list of hidden things reads as something rather than as CSS.
    public let label: String
    /// Its size and where it sat, measured when it was hidden -- a hidden
    /// element has no box to measure later, and two elements with the same
    /// label rarely share a shape and a corner.
    public let note: String
    public let dateHidden: Date

    public init(selector: String, label: String, note: String, dateHidden: Date) {
        self.selector = selector
        self.label = label
        self.note = note
        self.dateHidden = dateHidden
    }
}

/// Builds the stylesheet that keeps hidden elements hidden, and decides
/// which selectors are safe to put in it.
///
/// Selectors arrive from page script, so a page can send anything. The
/// sheet is assembled by string concatenation, which means a "selector"
/// containing a brace could close its rule and open a new one of its own --
/// hiding the page's sign-out button, say, or restyling another site's
/// content that shares the sheet's position in the cascade. Rejecting the
/// characters that can escape a selector is what keeps a page's own
/// submission confined to one `display: none` rule.
public enum HiddenElementStyleSheet {
    public static let maximumSelectorLength = 2048

    public static func isAcceptableSelector(_ selector: String) -> Bool {
        let trimmed = selector.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumSelectorLength else { return false }
        guard !trimmed.hasPrefix("@"), !trimmed.contains("/*"), !trimmed.contains("*/") else { return false }
        var quote: Character?
        var escaped = false
        var parens = 0
        var brackets = 0
        for character in trimmed {
            if character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return false
            }
            if escaped {
                escaped = false
                continue
            }
            switch character {
            case "\\":
                escaped = true
            case "{", "}":
                return false
            case ";":
                if quote == nil { return false }
            case "(", ")", "[", "]":
                guard quote == nil else { break }
                switch character {
                case "(": parens += 1
                case ")": parens -= 1
                case "[": brackets += 1
                default: brackets -= 1
                }
                if parens < 0 || brackets < 0 { return false }
            case "\"", "'":
                if quote == nil {
                    quote = character
                } else if quote == character {
                    quote = nil
                }
            default:
                break
            }
        }
        return quote == nil && !escaped && parens == 0 && brackets == 0
    }

    /// One rule per selector, so a selector the engine cannot parse drops
    /// only its own rule where a comma-joined list would drop them all. That
    /// holds only for selectors that pass isAcceptableSelector: an unclosed
    /// quote, bracket or parenthesis keeps the CSS parser inside it past the
    /// rule's end and swallows every rule after it.
    public static func css(for selectors: [String]) -> String {
        selectors
            .filter(isAcceptableSelector)
            .map { "\($0) { display: none !important; }" }
            .joined(separator: "\n")
    }
}

/// Per-profile record of what the user has hidden, keyed by site
/// (registrable domain), so an element hidden on `www.example.com` stays
/// hidden on `example.com` and `news.example.com` too.
///
/// With a `fileURL` it persists as JSON; with nil it lives only in memory,
/// which is what a private window's profile gets -- nothing keyed by a
/// private profile may reach the disk.
public final class HiddenElementStore {
    private let file: JSONFile<[String: [HiddenElement]]>?
    private var bySite: [String: [HiddenElement]]

    public static let maximumLabelLength = 120

    public init(fileURL: URL?) {
        if let fileURL {
            let file = JSONFile<[String: [HiddenElement]]>(url: fileURL)
            self.file = file
            bySite = file.load(default: [:])
        } else {
            file = nil
            bySite = [:]
        }
    }

    /// Suffixes under which unrelated owners each get their own subdomain
    /// (`alice.github.io`, `bob.github.io`). RegistrableDomain knows only
    /// registry suffixes, so without this every one of them would be one
    /// site: a hide on one owner's page would apply on every other's, and
    /// on CEF its selectors would be written into their pages. A short
    /// hand-kept list of the common hosts, not the Public Suffix List's
    /// private section -- a platform missing here still gets the coarser
    /// registrable-domain key.
    static let sharedHostingSuffixes: [String] = [
        "github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev", "workers.dev",
        "herokuapp.com", "blogspot.com", "wordpress.com", "tumblr.com", "substack.com",
        "web.app", "firebaseapp.com", "appspot.com", "azurewebsites.net", "cloudfront.net",
        "s3.amazonaws.com", "amplifyapp.com", "onrender.com", "fly.dev", "glitch.me",
        "neocities.org", "surge.sh", "ngrok.io", "ngrok-free.app", "repl.co", "replit.app",
        "readthedocs.io", "wixsite.com", "squarespace.com", "myshopify.com", "webflow.io",
        "carrd.co", "notion.site", "medium.com",
    ]

    /// The key a host's hidden elements are stored under: its registrable
    /// domain, or the whole host on a shared-hosting suffix.
    public static func site(forHost rawHost: String) -> String {
        var host = rawHost.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        for suffix in sharedHostingSuffixes where host.hasSuffix("." + suffix) {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return RegistrableDomain.of(host: host)
    }

    public var sites: [String] {
        bySite.keys.sorted()
    }

    public func elements(onSite site: String) -> [HiddenElement] {
        bySite[site.lowercased()] ?? []
    }

    /// False, and nothing stored, when the selector is unsafe or already
    /// hidden on that site.
    @discardableResult
    public func hide(selector: String, label: String, note: String, onSite site: String, at date: Date = Date()) -> Bool {
        let selector = selector.trimmingCharacters(in: .whitespaces)
        let site = site.lowercased()
        guard !site.isEmpty, HiddenElementStyleSheet.isAcceptableSelector(selector) else { return false }
        var list = bySite[site] ?? []
        guard !list.contains(where: { $0.selector == selector }) else { return false }
        list.append(HiddenElement(
            selector: selector,
            label: Self.clip(label.isEmpty ? selector : label),
            note: Self.clip(note),
            dateHidden: date
        ))
        bySite[site] = list
        save()
        return true
    }

    public func restore(selector: String, onSite site: String) {
        let site = site.lowercased()
        guard var list = bySite[site] else { return }
        list.removeAll { $0.selector == selector }
        bySite[site] = list.isEmpty ? nil : list
        save()
    }

    public func restoreAll(onSite site: String) {
        guard bySite.removeValue(forKey: site.lowercased()) != nil else { return }
        save()
    }

    /// Every site's stylesheet, for handing to a tab so it can apply the
    /// right one to whatever document it loads next.
    public var styleSheetsBySite: [String: String] {
        bySite.compactMapValues { elements in
            let css = HiddenElementStyleSheet.css(for: elements.map(\.selector))
            return css.isEmpty ? nil : css
        }
    }

    private func save() {
        file?.save(bySite)
    }

    private static func clip(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > maximumLabelLength else { return collapsed }
        return String(collapsed.prefix(maximumLabelLength - 1)) + "…"
    }
}
