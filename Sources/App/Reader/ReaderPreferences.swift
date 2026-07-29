import Foundation

/// Reader mode's font-size setting -- persisted globally (not per-profile),
/// matching Safari/most reader-mode implementations treating this as a
/// personal reading preference rather than a per-site/per-profile one.
enum ReaderFontSize: String, CaseIterable {
    case small, medium, large

    var scale: Double {
        switch self {
        case .small: return 0.85
        case .medium: return 1.0
        case .large: return 1.25
        }
    }

    var title: String {
        switch self {
        case .small: return "Small Text"
        case .medium: return "Medium Text"
        case .large: return "Large Text"
        }
    }
}

enum ReaderFontSizePreference {
    private static let key = "BrowserReaderFontSize"

    static var current: ReaderFontSize {
        get {
            // AppPreferencesStore.current, not .standard directly (browser-
            // xrq) -- see that type's own doc comment for why.
            guard let raw = AppPreferencesStore.current.string(forKey: key), let size = ReaderFontSize(rawValue: raw) else {
                return .medium
            }
            return size
        }
        set {
            AppPreferencesStore.current.set(newValue.rawValue, forKey: key)
        }
    }
}
