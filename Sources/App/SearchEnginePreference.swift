import Foundation

extension Notification.Name {
    /// Posted whenever the engine, the custom template, or either of the two
    /// opt-in toggles changes -- same "post on change, anything interested
    /// observes" shape as .omniboxDisplayPreferenceDidChange. The omnibox
    /// reads the preference at the moment it resolves what was typed, so
    /// nothing has to observe this today; it exists so a future live UI
    /// (a suggestion row already on screen when the engine changes) has
    /// something to hang off.
    static let searchEnginePreferenceDidChange = Notification.Name("SearchEnginePreferenceDidChange")
}

/// The omnibox's search engine, plus the two network-touching features that
/// hang off it (browser-0du). Persisted globally rather than per-profile,
/// matching OmniboxDisplayPreference's reasoning: which search engine you
/// use is a personal habit, not a property of the identity you happen to be
/// browsing as.
enum SearchEnginePreference {
    private static let choiceKey = "BrowserSearchEngineChoice"
    private static let customTemplateKey = "BrowserSearchEngineCustomTemplate"
    private static let suggestionsKey = "BrowserSearchSuggestionsEnabled"
    private static let quickSiteSearchKey = "BrowserQuickWebsiteSearchEnabled"

    static var choice: SearchEngineChoice {
        get {
            // AppPreferencesStore.current, not .standard directly (browser-
            // xrq) -- see that type's own doc comment for why.
            guard let raw = AppPreferencesStore.current.string(forKey: choiceKey),
                  let choice = SearchEngineChoice(rawValue: raw) else {
                return SearchEngine.default.choice
            }
            return choice
        }
        set {
            AppPreferencesStore.current.set(newValue.rawValue, forKey: choiceKey)
            NotificationCenter.default.post(name: .searchEnginePreferenceDidChange, object: nil)
        }
    }

    /// The custom engine's template exactly as typed, for redisplay in the
    /// settings field. It may be invalid -- `current` falls back when it is.
    static var customTemplate: String {
        get { AppPreferencesStore.current.string(forKey: customTemplateKey) ?? "" }
        set {
            AppPreferencesStore.current.set(newValue, forKey: customTemplateKey)
            NotificationCenter.default.post(name: .searchEnginePreferenceDidChange, object: nil)
        }
    }

    /// The engine to actually search with. Falls back to the default rather
    /// than failing: "Custom" selected with an unusable template must still
    /// leave the omnibox able to search, or Enter on any typed phrase does
    /// nothing at all and the browser looks broken.
    static var current: SearchEngine {
        let choice = self.choice
        if choice == .custom, let custom = SearchEngine.custom(template: customTemplate) { return custom }
        return SearchEngine.builtIn(choice) ?? SearchEngine.default
    }

    /// Live search suggestions from the engine. **Opt-in, and off by
    /// default.** Every keystroke typed into the omnibox becomes an HTTP
    /// request to the search engine when this is on, which is a real privacy
    /// cost and one this browser's landing page promises not to impose
    /// without asking. Defaulting it off is what keeps that promise true;
    /// the settings copy states plainly what turning it on sends.
    ///
    /// Being on is never enough on its own: a private window checks
    /// `isPrivate` and refuses to fetch regardless (see
    /// SearchSuggestionFetcher and OmniboxAutocompleteController).
    static var suggestionsEnabled: Bool {
        get { AppPreferencesStore.current.bool(forKey: suggestionsKey) }
        set {
            AppPreferencesStore.current.set(newValue, forKey: suggestionsKey)
            NotificationCenter.default.post(name: .searchEnginePreferenceDidChange, object: nil)
        }
    }

    /// Quick Website Search. On by default: unlike suggestions it sends
    /// nothing anywhere -- the keywords are derived from history that is
    /// already on disk, and a search only leaves the machine once the user
    /// presses Return, to the site they asked for.
    static var quickSiteSearchEnabled: Bool {
        get {
            guard AppPreferencesStore.current.object(forKey: quickSiteSearchKey) != nil else { return true }
            return AppPreferencesStore.current.bool(forKey: quickSiteSearchKey)
        }
        set {
            AppPreferencesStore.current.set(newValue, forKey: quickSiteSearchKey)
            NotificationCenter.default.post(name: .searchEnginePreferenceDidChange, object: nil)
        }
    }
}
