import Foundation

/// Global (not per-profile) link-handling preferences, shown as "Link
/// Handling" in the Privacy pane (browser-ymx). Backed by
/// AppPreferencesStore, not UserDefaults.standard directly (browser-xrq --
/// see that type's own doc comment), matching every other global
/// preference in this app (ReaderFontSizePreference, OmniboxDisplayPreference).
enum LinkHandlingPreferences {
    private static let stripTrackingParamsKey = "BrowserStripTrackingParams"
    private static let unshortenLinksKey = "BrowserUnshortenLinks"

    /// Defaults to true: stripping is pure, synchronous, and has no
    /// user-visible downside (a link opens exactly where it would have,
    /// just without ?utm_source=... hanging off it) -- Brady's own request
    /// specifically asked for this default.
    static var stripTrackingParams: Bool {
        get {
            guard AppPreferencesStore.current.object(forKey: stripTrackingParamsKey) != nil else { return true }
            return AppPreferencesStore.current.bool(forKey: stripTrackingParamsKey)
        }
        set { AppPreferencesStore.current.set(newValue, forKey: stripTrackingParamsKey) }
    }

    /// Defaults to false: un-shortening means a real network round-trip
    /// before a link even opens, which is a materially bigger behavior
    /// change than stripping -- Brady's own request specifically asked for
    /// this to be opt-in.
    static var unshortenLinks: Bool {
        get { AppPreferencesStore.current.bool(forKey: unshortenLinksKey) }
        set { AppPreferencesStore.current.set(newValue, forKey: unshortenLinksKey) }
    }

    /// "Open links from other apps in a little window". Defaults to false,
    /// so a link from another app opens as a tab exactly as it always has
    /// for anyone who hasn't chosen otherwise. A routing rule's own `openIn`
    /// overrides this either way (see LinkOpening.resolve). `browser
    /// route-test` reads the same key; see LinkHandlingPreferencesReader.
    static let littleWindowForExternalLinksKey = "BrowserLittleWindowForExternalLinks"

    static var littleWindowForExternalLinks: Bool {
        get { AppPreferencesStore.current.bool(forKey: littleWindowForExternalLinksKey) }
        set { AppPreferencesStore.current.set(newValue, forKey: littleWindowForExternalLinksKey) }
    }
}
