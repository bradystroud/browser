import AppKit

// The engine-agnostic surface of browser extensions. The engine owns the
// extensions themselves -- installing, loading, permissions, their pages --
// and asks the app, through the `ExtensionHost*` protocols, about the
// browser around them: which windows and tabs exist, which is in front,
// where a new tab goes, whether the user agrees. UI code talks to
// `ActiveEngine.extensions` and never to an engine's own extension types.

/// A browser tab as extensions see it. Implemented by the app.
protocol ExtensionHostTab: AnyObject {
    /// Nil while the tab has no engine-side browser yet.
    var extensionEngineTab: EngineTab? { get }
    var extensionTitle: String { get }
    var extensionURL: URL? { get }
    var extensionIsLoading: Bool { get }
    var extensionIsPinned: Bool { get }
    var extensionWindow: ExtensionHostWindow? { get }
    func extensionLoad(_ url: URL)
    func extensionActivate()
    func extensionClose()
    func extensionSetPinned(_ pinned: Bool)
}

/// A browser window as extensions see it. Implemented by the app.
protocol ExtensionHostWindow: AnyObject {
    var extensionProfileId: String { get }
    /// In strip order.
    var extensionTabs: [ExtensionHostTab] { get }
    var extensionActiveTab: ExtensionHostTab? { get }
    var extensionNSWindow: NSWindow? { get }
    func extensionOpenTab(url: URL?, active: Bool) -> ExtensionHostTab?
    func extensionClose()
    /// The toolbar view an extension's popup hangs from: its pinned button,
    /// or the extensions button when it isn't pinned.
    func extensionPopupAnchor(forExtension id: String) -> NSView?
}

/// Something an extension wants that the user must agree to first.
struct ExtensionConsentRequest {
    let title: String
    let message: String
    let icon: NSImage?
    let allowTitle: String
}

/// The app's side of the extension system. Everything here is main-thread.
protocol ExtensionHost: AnyObject {
    /// The profile's open (non-private) windows, frontmost first.
    func extensionWindows(profileId: String) -> [ExtensionHostWindow]
    func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool) -> ExtensionHostWindow?
    /// One question at a time, attached to a browser window where there is
    /// one, so the rest of the browser keeps running while it waits.
    func extensionConfirm(_ request: ExtensionConsentRequest) async -> Bool
    /// A short, user-facing outcome (installed, updated, failed to load).
    func extensionNotify(_ message: String, profileId: String)
    /// The profile's extension list, or an extension's toolbar button,
    /// changed.
    func extensionsDidChange(profileId: String)
}

enum EngineExtensionSource {
    case webStore
    case unpacked(path: String)
}

/// An extension's toolbar button for one tab.
struct EngineExtensionAction {
    let label: String
    let icon: NSImage?
    let badgeText: String
    let isEnabled: Bool
}

struct EngineExtensionSummary {
    let id: String
    let name: String
    let version: String
    let description: String
    let icon: NSImage?
    let source: EngineExtensionSource
    let isEnabled: Bool
    let isPinned: Bool
    /// Loaded and running. False while disabled, or when it failed to load.
    let isLoaded: Bool
    let hasOptionsPage: Bool
    /// What went wrong loading or running it, newest last.
    let errors: [String]
}

struct EngineExtensionTabChange: OptionSet {
    let rawValue: Int
    static let url = EngineExtensionTabChange(rawValue: 1 << 0)
    static let title = EngineExtensionTabChange(rawValue: 1 << 1)
    static let loading = EngineExtensionTabChange(rawValue: 1 << 2)
    static let pinned = EngineExtensionTabChange(rawValue: 1 << 3)
}

/// One engine's extension system. Only exists where
/// `EngineCapabilities.webExtensions` is true.
///
/// Extensions are per profile: each profile has its own installed list,
/// storage and permissions, kept in that profile's directory. Private
/// windows never run extensions and nothing about them is written down.
protocol EngineExtensionManager: AnyObject {
    /// Starts the system. `storageDirectory` gives the directory a
    /// profile's extensions live in, or nil for a profile whose extensions
    /// must not be written down (a private one).
    func activate(host: ExtensionHost, storageDirectory: @escaping (String) -> URL?)

    /// Loads the profile's enabled extensions, once per run. Called when the
    /// profile's first window opens.
    func loadExtensions(profileId: String)

    /// Stops everything the profile runs and forgets it, without touching
    /// its folder. Called when the profile is deleted.
    func unloadProfile(profileId: String)

    func extensions(profileId: String) -> [EngineExtensionSummary]
    func action(extensionId: String, profileId: String, tab: ExtensionHostTab?) -> EngineExtensionAction?

    /// A Chrome Web Store link or a bare extension id.
    @MainActor func installFromWebStore(_ linkOrID: String, profileId: String) async throws
    /// Chooses nothing itself: `folder` holds the extension's manifest.json.
    @MainActor func loadUnpacked(folder: URL, profileId: String) async throws
    /// Reads the extension again -- from its folder for an unpacked one --
    /// asking again if it now wants more than it was allowed.
    @MainActor func reload(extensionId: String, profileId: String) async throws
    func remove(extensionId: String, profileId: String)
    func setEnabled(_ enabled: Bool, extensionId: String, profileId: String)
    func setPinned(_ pinned: Bool, extensionId: String, profileId: String)
    func openOptionsPage(extensionId: String, profileId: String)
    /// The toolbar button was pressed: shows its popup or tells the
    /// extension it was clicked.
    func performAction(extensionId: String, window: ExtensionHostWindow)
    /// Asks the store for newer versions when the daily check is due, or
    /// always when `force`. Returns how many extensions were updated.
    @MainActor @discardableResult
    func checkForUpdates(profileId: String, force: Bool) async -> Int

    func windowDidOpen(_ window: ExtensionHostWindow)
    func windowDidClose(_ window: ExtensionHostWindow)
    func windowDidBecomeFocused(_ window: ExtensionHostWindow)
    func tabDidOpen(_ tab: ExtensionHostTab)
    func tabDidClose(_ tab: ExtensionHostTab, windowIsClosing: Bool)
    func tabDidActivate(_ tab: ExtensionHostTab, previous: ExtensionHostTab?)
    func tabDidChange(_ tab: ExtensionHostTab, _ change: EngineExtensionTabChange)
}
