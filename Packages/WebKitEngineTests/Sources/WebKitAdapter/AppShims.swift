import AppKit

// Stand-ins for app types the Engine/ files name but the tests never reach
// (CEFEngine is only named by Engines.swift's switch); they exist so the
// adapter compiles outside Browser.app.

enum CommandLineArgs {
    static func testNoActivate() -> Bool { true }
}

enum CEFEngine: BrowserEngine {
    static func bootstrapApplication() {}
    static var capabilities: EngineCapabilities {
        EngineCapabilities(inAppDevTools: false, responsiveDesignMode: false, perTabCPUUsage: false, perTabAudioMute: false, customContextMenuItems: false)
    }
    static func initialize(profilesRootPath: String) -> Bool { false }
    static func createTab(profileName: String, profileId: String, hostView: NSView, initialURL: String) -> EngineTab {
        fatalError("CEF is not available in the WebKit adapter test harness")
    }
    static func createPrivateTab(hostView: NSView, initialURL: String) -> EngineTab {
        fatalError("CEF is not available in the WebKit adapter test harness")
    }
    static func setWindowCloseHandler(_ handler: @escaping () -> Void) {}
    static var isTerminating: Bool { false }
    static func setVisualLookUpAvailable(_ available: Bool) {}
    static func setBackgroundTabPolicy(_ policy: BackgroundTabPolicy) {}
    static func setDownloadDirectory(_ path: String) {}
    static func updateContentBlocking(domains: [String], profileSettings: [String: EngineProfileBlockingSettings]) {}
    static func setThreatInterstitialBuilder(_ builder: @escaping (String, String) -> String) {}
    static func updateThreatBlocking(domains: [String], profileSettings: [String: EngineProfileThreatSettings]) {}
}
