import AppKit

// The engine-agnostic surface of browser extensions. The engine owns the
// extensions themselves -- installing, loading, permissions, their pages --
// and asks the app, through the `ExtensionHost*` protocols, about the
// browser around them: which windows and tabs exist, which is in front,
// where a new tab goes, whether the user agrees. UI code talks to
// `Engines.extensions` and never to an engine's own extension types.

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
    /// The same, with the tab in `engine` and kept there for the page:
    /// an extension's own page exists separately in each engine's runtime,
    /// so a page one runtime opened must not open in the other. Nil means
    /// whichever engine the rules pick.
    func extensionOpenTab(url: URL?, active: Bool, engine: EngineChoice?) -> ExtensionHostTab?
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
    /// The manifest of the extension being installed, loaded or updated,
    /// for a runtime that would also run it and must say what that means
    /// (FollowerExtensionRuntime.consentNote). Nil for a request that only
    /// concerns the asking runtime.
    var manifest: [String: Any]? = nil
}

/// The app's side of the extension system. Everything here is main-thread.
protocol ExtensionHost: AnyObject {
    /// The profile's open (non-private) windows, frontmost first.
    func extensionWindows(profileId: String) -> [ExtensionHostWindow]
    func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool) -> ExtensionHostWindow?
    /// The same, with the first tab in `engine` (see
    /// ExtensionHostWindow.extensionOpenTab(url:active:engine:)).
    func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool, engine: EngineChoice?) -> ExtensionHostWindow?
    /// Shows an extension's toolbar popup that its engine cannot show by
    /// itself. False when nothing was shown.
    func extensionPresentPopup(_ request: EngineExtensionPopupRequest) -> Bool
    /// One question at a time, attached to a browser window where there is
    /// one, so the rest of the browser keeps running while it waits.
    func extensionConfirm(_ request: ExtensionConsentRequest) async -> Bool
    /// A short, user-facing outcome (installed, updated, failed to load).
    func extensionNotify(_ message: String, profileId: String)
    /// The profile's extension list, or an extension's toolbar button,
    /// changed.
    func extensionsDidChange(profileId: String)
}

extension ExtensionHostWindow {
    func extensionOpenTab(url: URL?, active: Bool, engine: EngineChoice?) -> ExtensionHostTab? {
        extensionOpenTab(url: url, active: active)
    }
}

extension ExtensionHost {
    func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool, engine: EngineChoice?) -> ExtensionHostWindow? {
        extensionOpenWindow(profileId: profileId, urls: urls, focused: focused)
    }

    func extensionPresentPopup(_ request: EngineExtensionPopupRequest) -> Bool { false }
}

/// An extension's popup page to show over a window's toolbar, in a tab of
/// `engine` in the profile.
struct EngineExtensionPopupRequest {
    let extensionId: String
    let profileId: String
    let engine: EngineChoice
    let url: URL
    /// The window whose button was pressed, or nil when the extension asked
    /// by itself (`action.openPopup`); the profile's front window then.
    weak var window: ExtensionHostWindow?
    /// Whether the extension asked by itself rather than the user pressing
    /// its button.
    let requestedByExtension: Bool
}

/// How one installed extension stands in a runtime other than the one that
/// owns the install list (the summary's own `isLoaded` and `errors`).
struct EngineExtensionRuntimeStatus: Equatable {
    /// It runs in that engine's tabs in this session, or will once the
    /// profile opens its first tab there.
    var isRunning: Bool
    /// What runs in that engine's tabs differs from the list now (installed,
    /// removed, enabled, disabled, updated, reloaded since launch); it
    /// catches up when the app relaunches.
    var needsRelaunch: Bool
    /// Why it cannot run there, when it cannot.
    var unavailableReason: String?
    /// A store install from before the app kept the store key: it runs there
    /// after one download of the package, which the app makes on its own.
    var isWaitingForKey: Bool
    /// That engine would grant it more than the user agreed to; it runs
    /// there only after the user approves `approvalGrants`
    /// (EngineExtensionManager.approveRuntimeGrants).
    var needsApproval: Bool = false
    /// Everything that engine would grant it, in the `perm:`/`host:` form
    /// of `InstalledWebExtension.grants`.
    var approvalGrants: [String] = []
}

/// An extension that was removed and still runs in an engine's tabs until
/// the app relaunches.
struct EngineExtensionStillRunning: Equatable {
    let id: String
    let name: String
    let engine: EngineChoice
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
    /// Why the extension cannot act in this tab, when it cannot, for the
    /// button to say instead of doing nothing.
    var disabledReason: String? = nil
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
    /// Its state in each other engine that runs the same install list.
    var runtimes: [EngineChoice: EngineExtensionRuntimeStatus] = [:]
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

    /// The user approved `grants`: exactly the
    /// `EngineExtensionRuntimeStatus.approvalGrants` the sheet showed for
    /// `engine`. Only that list is recorded. False when nothing was recorded
    /// (no approval pending) or when what the engine would grant now goes
    /// beyond it; the extension then still needs approval.
    @discardableResult
    func approveRuntimeGrants(extensionId: String, profileId: String, engine: EngineChoice, grants: [String]) -> Bool
    /// Extensions removed from the profile that still run somewhere until
    /// the app relaunches.
    func extensionsStillRunningAfterRemoval(profileId: String) -> [EngineExtensionStillRunning]
    /// Looks at the profile's extensions again, including what an engine
    /// only checks when asked (an unpacked folder's files). Off the main
    /// thread; a change is reported as usual.
    func refreshRuntimeStatus(profileId: String)
}

extension EngineExtensionManager {
    func approveRuntimeGrants(extensionId: String, profileId: String, engine: EngineChoice, grants: [String]) -> Bool { false }
    func extensionsStillRunningAfterRemoval(profileId: String) -> [EngineExtensionStillRunning] { [] }
    func refreshRuntimeStatus(profileId: String) {}
}
