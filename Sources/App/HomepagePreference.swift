import Foundation

extension Notification.Name {
    /// Posted whenever the homepage URL or the new-window content choice
    /// changes -- same "post on change, anything interested observes" shape
    /// as .omniboxDisplayPreferenceDidChange (see OmniboxDisplayPreference).
    /// Nothing observes it today: ⌘N reads the preference at the moment it
    /// opens a window, so there is no live UI to refresh. It exists for the
    /// Home button and the ⌘T half (browser-m0x), which will need it.
    static let homepagePreferenceDidChange = Notification.Name("HomepagePreferenceDidChange")
}

/// What a newly opened window shows (browser-m0x) -- Safari's "New windows
/// open with" picker. Safari also offers "Same Page", which is deliberately
/// not modelled here: it means "whatever the frontmost window is showing",
/// which has no answer when ⌘N is pressed with no window open at all.
enum NewWindowContent: String, CaseIterable {
    case startPage
    case homepage
    case emptyPage

    var title: String {
        switch self {
        case .startPage: return "Start Page"
        case .homepage: return "Homepage"
        case .emptyPage: return "Empty Page"
        }
    }
}

/// The homepage URL and the new-window content choice, persisted globally
/// rather than per-profile. Global matches OmniboxDisplayPreference's own
/// reasoning -- "what ⌘N does" is a personal habit, not a property of the
/// identity you happen to be browsing as -- and it keeps ⌘N answerable
/// before any profile has been resolved.
enum HomepagePreference {
    private static let contentKey = "BrowserNewWindowContent"
    private static let homepageKey = "BrowserHomepageURL"

    /// `Tab`'s sentinel for "show the internal start page" (see Tab.swift's
    /// `blankPageSentinel`). Passing this as an `initialURL` never actually
    /// navigates anywhere -- Tab intercepts it and renders StartPageRenderer's
    /// data URL instead.
    static let startPageURL = "about:blank"

    /// A genuinely blank document. It has to be a real URL rather than
    /// `about:blank`, because that string is already spoken for as the start
    /// page sentinel above. Ours, never user input -- the `data:` scheme is
    /// rejected outright in a user-typed homepage (see `normalized(_:)`).
    static let emptyPageURL = "data:text/html,"

    /// Schemes a user-typed homepage may use. `javascript:` and `data:` are
    /// excluded on purpose: both let a homepage execute script that would
    /// then run automatically on every ⌘N, which is a footgun a homepage
    /// field has no business offering. `file:` stays allowed -- a local HTML
    /// start page is a legitimate, long-standing thing to want.
    private static let allowedSchemes: Set<String> = ["http", "https", "file"]

    static var newWindowContent: NewWindowContent {
        get {
            // AppPreferencesStore.current, not .standard directly (browser-
            // xrq) -- see that type's own doc comment for why.
            guard let raw = AppPreferencesStore.current.string(forKey: contentKey),
                  let content = NewWindowContent(rawValue: raw) else {
                return .startPage
            }
            return content
        }
        set {
            AppPreferencesStore.current.set(newValue.rawValue, forKey: contentKey)
            NotificationCenter.default.post(name: .homepagePreferenceDidChange, object: nil)
        }
    }

    /// The homepage exactly as the user typed it, for redisplay in the
    /// settings field. Never navigate to this directly -- use `newWindowURL`,
    /// which resolves and validates it.
    static var homepage: String {
        get { AppPreferencesStore.current.string(forKey: homepageKey) ?? "" }
        set {
            AppPreferencesStore.current.set(newValue, forKey: homepageKey)
            NotificationCenter.default.post(name: .homepagePreferenceDidChange, object: nil)
        }
    }

    /// The URL a new window should open, already resolved and validated.
    ///
    /// The homepage case falls back to the start page whenever the stored
    /// homepage is unusable -- blank, malformed, or carrying a scheme we
    /// refuse. The settings field also rejects those at entry, so this is
    /// belt and braces rather than the only guard, and it is the one that
    /// matters: it holds for a value that never went through the field at
    /// all (a hand-edited defaults domain, or a key written by a future
    /// build). A blank setting must never become a navigation to nowhere.
    static var newWindowURL: String {
        switch newWindowContent {
        case .startPage: return startPageURL
        case .emptyPage: return emptyPageURL
        case .homepage: return normalized(homepage) ?? startPageURL
        }
    }

    /// Turns what the user typed into a URL worth navigating to, or nil if
    /// it isn't one. Deliberately *not* a search fallback: the omnibox turns
    /// "hello world" into a DuckDuckGo query (see BrowserWindowController's
    /// `OmniboxSubmission.resolve`), but a homepage silently becoming a search
    /// for its own text is a setting behaving as though it were accepted when
    /// it wasn't. Rejecting it is what lets the field say so.
    ///
    /// The scheme-less rule is `OmniboxSubmission.resolve`'s own, on purpose,
    /// so "example.org" means the same thing typed into either place.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            // Same "looks like a domain" test the omnibox uses.
            guard trimmed.contains("."), !trimmed.contains(" ") else { return nil }
            candidate = "https://" + trimmed
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else { return nil }
        // http(s) without a host ("https://") parses fine but goes nowhere.
        // file: URLs legitimately have no host, so the check is scheme-aware.
        if scheme != "file", url.host?.isEmpty ?? true { return nil }
        return candidate
    }
}
