import Foundation

/// Global "Scroll with the middle button" preference. Off by default: it
/// changes what a middle click on the page does, which should be a choice.
/// Backed by AppPreferencesStore, like every other global preference.
enum AutoScrollPreference {
    static let key = "BrowserMiddleClickAutoscroll"

    static var isEnabled: Bool {
        get { AppPreferencesStore.current.bool(forKey: key) }
        set {
            AppPreferencesStore.current.set(newValue, forKey: key)
            applyToOpenTabs(newValue)
        }
    }

    /// New documents pick the setting up on load; this reaches the pages
    /// already showing, so a change takes effect without reloading.
    private static func applyToOpenTabs(_ enabled: Bool) {
        let script = enabled ? AutoScrollScript.source : AutoScrollScript.disable
        for controller in WindowManager.shared.windowControllers {
            for tab in controller.tabs where !tab.isShowingStartPage {
                tab.executeJavaScript(script)
            }
        }
    }
}
