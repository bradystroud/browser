import AppKit

// Opening a tab or window in a chosen engine, for an extension runtime whose
// own pages exist only in its engine (see ExtensionHostWindow).

extension ExtensionsCoordinator {
    /// Where a profile's extension install list and store packages live, or
    /// nil for a private profile. The one definition: the WebKit manager is
    /// given it on activation, and the CEF runtime before the engine starts
    /// (Engines.setExtensionStorageDirectory).
    /// Never the profile's Extensions/ (see WebExtensionsFolder): what an
    /// earlier version kept there is moved out first, before anything reads
    /// the list.
    static func storageDirectory(profileId: String) -> URL? {
        guard !profileId.hasPrefix(Profile.privateIdPrefix) else { return nil }
        let profileDirectory = URL(fileURLWithPath: CommandLineArgs.profileDirectory(profileId: profileId), isDirectory: true)
        return WebExtensionsFolder.prepared(inProfile: profileDirectory) { message in
            NSLog("Browser: extensions of profile %@: %@", profileId, message)
        }
    }

    /// Never activates the app: an extension acts in the background, and the
    /// user may be typing in another app. `focused` brings the window
    /// forward only when the app is already active.
    func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool, engine: EngineChoice?) -> ExtensionHostWindow? {
        guard !Engines.isTerminating, let profile = ProfileManager.shared.profile(id: profileId) else { return nil }
        let first = urls.first?.absoluteString ?? HomepagePreference.newWindowURL
        let controller = WindowManager.shared.openNewWindow(profile: profile, initialURL: first, activateApp: false,
                                                            initialTabEngine: engine)
        for url in urls.dropFirst() {
            if let engine, url.scheme?.lowercased() == "chrome-extension" {
                controller.addTab(url: url.absoluteString, makeActive: false, engine: engine)
            } else {
                controller.addTab(url: url.absoluteString, makeActive: false)
            }
        }
        if focused, NSApp.isActive { controller.window?.makeKeyAndOrderFront(nil) }
        return windowHandle(for: controller)
    }
}

extension ExtensionWindowHandle {
    func extensionOpenTab(url: URL?, active: Bool, engine: EngineChoice?) -> ExtensionHostTab? {
        guard let engine else { return extensionOpenTab(url: url, active: active) }
        guard let controller else { return nil }
        let tab = controller.addTab(url: url?.absoluteString ?? "about:blank", makeActive: active, engine: engine)
        return ExtensionsCoordinator.shared.tabHandle(for: tab, in: controller)
    }
}
