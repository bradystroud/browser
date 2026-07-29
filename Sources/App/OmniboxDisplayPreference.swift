import Foundation

extension Notification.Name {
    /// Posted whenever OmniboxDisplayPreference.current changes, so every
    /// open window's collapsed omnibox pill refreshes immediately rather
    /// than waiting for that tab's next navigation/title change -- same
    /// "post on change, any window observes" shape as
    /// .profileManagerDidChange (see ProfileManager.swift).
    static let omniboxDisplayPreferenceDidChange = Notification.Name("OmniboxDisplayPreferenceDidChange")
}

/// What the omnibox pill shows while collapsed/unfocused (browser-0y1,
/// Brady's ask) -- on focus/⌘L it always expands to the full editable URL
/// regardless of this setting, unchanged from before. Persisted globally
/// (not per-profile), matching ReaderFontSizePreference's own reasoning:
/// this is a personal display preference, not a per-site/per-profile one.
enum OmniboxDisplayMode: String, CaseIterable {
    case domainOnly
    case pageTitle
    case fullURL

    var title: String {
        switch self {
        case .domainOnly: return "Domain Only"
        case .pageTitle: return "Page Title"
        case .fullURL: return "Full URL"
        }
    }
}

enum OmniboxDisplayPreference {
    private static let key = "BrowserOmniboxDisplayMode"

    static var current: OmniboxDisplayMode {
        get {
            // AppPreferencesStore.current, not .standard directly (browser-
            // xrq) -- see that type's own doc comment for why.
            guard let raw = AppPreferencesStore.current.string(forKey: key), let mode = OmniboxDisplayMode(rawValue: raw) else {
                return .domainOnly
            }
            return mode
        }
        set {
            AppPreferencesStore.current.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .omniboxDisplayPreferenceDidChange, object: nil)
        }
    }
}
