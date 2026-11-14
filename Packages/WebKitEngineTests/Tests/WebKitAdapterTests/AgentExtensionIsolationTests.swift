import WebKit
import XCTest
@testable import WebKitAdapter

/// A tab built with `runsExtensions: false` -- what an agent's page gets --
/// against a real installed extension: no content script runs in it, and
/// the extension's own page does not load in it. A tab built the normal way
/// gets both, which is the control.
@available(macOS 15.4, *)
@MainActor
final class AgentExtensionIsolationTests: XCTestCase {
    private final class FakeHost: ExtensionHost {
        func extensionWindows(profileId: String) -> [ExtensionHostWindow] { [] }
        func extensionOpenWindow(profileId: String, urls: [URL], focused: Bool) -> ExtensionHostWindow? { nil }
        func extensionConfirm(_ request: ExtensionConsentRequest) async -> Bool { false }
        func extensionNotify(_ message: String, profileId: String) {}
        func extensionsDidChange(profileId: String) {}
    }

    private var manager: WebKitExtensionManager { .shared }
    private var host: FakeHost!
    private var root: URL!
    private var profileId: String!
    private var server: LocalHTTPServer!
    private var window: NSWindow!
    private var tabs: [WebKitTab] = []

    private let extensionId = String(repeating: "k", count: 32)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brw-agent-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        host = FakeHost()
        let root = root!
        manager.activate(host: host, storageDirectory: { id in
            id.hasPrefix("private-") ? nil : root.appendingPathComponent(id).appendingPathComponent("Extensions", isDirectory: true)
        })
        profileId = UUID().uuidString
        server = try LocalHTTPServer(routes: ["/page": .html("<!doctype html><title>site</title><p>site</p>")])
        try server.start()
        window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        try await installMarkerExtension()
    }

    override func tearDown() async throws {
        tabs.forEach { $0.close() }
        tabs = []
        manager.unloadProfile(profileId: profileId)
        window?.orderOut(nil)
        window = nil
        server?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    /// A content script on every site that marks the page, and a page of
    /// its own that marks itself.
    private func installMarkerExtension() async throws {
        let extensions = root.appendingPathComponent(profileId).appendingPathComponent("Extensions", isDirectory: true)
        let folder = extensions.appendingPathComponent(extensionId, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Marker", "version": "1.0",
            "host_permissions": ["<all_urls>"],
            "content_scripts": [["matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end"]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.setAttribute('data-marker-extension', 'ran');".utf8)
            .write(to: folder.appendingPathComponent("content.js"))
        try Data("<!doctype html><title>extension page</title><body data-extension-page=\"yes\">ext</body>".utf8)
            .write(to: folder.appendingPathComponent("page.html"))
        let record = InstalledWebExtension(id: extensionId, source: .webStore, name: "Marker", version: "1.0",
                                           grants: ["host:<all_urls>"])
        try InstalledWebExtensionList(extensions: [record]).save(to: extensions.appendingPathComponent("installed.json"))
        manager.loadExtensions(profileId: profileId)
        let deadline = Date().addingTimeInterval(10)
        while manager.profile(for: profileId)?.contexts[extensionId] == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(manager.profile(for: profileId)?.contexts[extensionId], "the marker extension never loaded")
    }

    private func makeTab(_ url: String, runsExtensions: Bool) throws -> WebKitTab {
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView?.addSubview(hostView)
        let tab = try XCTUnwrap(WebKitEngine.createTab(
            profileName: "agent-ext-test", profileId: profileId, hostView: hostView,
            initialURL: url, runsExtensions: runsExtensions) as? WebKitTab)
        tabs.append(tab)
        return tab
    }

    private func evaluate(_ tab: WebKitTab, _ script: String) async -> Any? {
        try? await tab.webView.evaluateJavaScript(script)
    }

    /// Waits for `script` to return a non-nil, non-NSNull value, or gives up.
    private func poll(_ tab: WebKitTab, _ script: String, seconds: Double) async -> Any? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = await evaluate(tab, script), !(value is NSNull) { return value }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func waitForLoad(_ tab: WebKitTab) async {
        let deadline = Date().addingTimeInterval(10)
        while tab.webView.isLoading || tab.webView.url == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func testAgentTabHasNoExtensionController() throws {
        let tab = try makeTab("", runsExtensions: false)
        XCTAssertNil(tab.webView.configuration.webExtensionController)
        let normal = try makeTab("", runsExtensions: true)
        XCTAssertTrue(normal.webView.configuration.webExtensionController === manager.profile(for: profileId)?.controller)
    }

    func testContentScriptRunsInANormalTabOnly() async throws {
        let marker = "document.documentElement.getAttribute('data-marker-extension')"
        let normal = try makeTab(server.url("/page"), runsExtensions: true)
        let ran = await poll(normal, marker, seconds: 10)
        XCTAssertEqual(ran as? String, "ran", "control: the content script runs in a normal tab")

        let agent = try makeTab(server.url("/page"), runsExtensions: false)
        await waitForLoad(agent)
        let title = await evaluate(agent, "document.title")
        XCTAssertEqual(title as? String, "site", "the agent tab loaded the page")
        let none = await poll(agent, marker, seconds: 2)
        XCTAssertNil(none, "no content script in a tab that may not run extensions")
    }

    func testExtensionPageLoadsInANormalTabOnly() async throws {
        let pageURL = "chrome-extension://\(extensionId)/page.html"
        let probe = "document.body && document.body.getAttribute('data-extension-page')"

        let normal = try makeTab(pageURL, runsExtensions: true)
        let shown = await poll(normal, probe, seconds: 10)
        XCTAssertEqual(shown as? String, "yes", "control: an extension page opens in a normal tab")
        let runtimeId = await evaluate(normal, "typeof chrome !== 'undefined' && chrome.runtime ? chrome.runtime.id : null")
        XCTAssertNotNil(runtimeId as? String, "control: the extension page has the extension API")

        let agent = try makeTab(pageURL, runsExtensions: false)
        let refused = await poll(agent, probe, seconds: 3)
        XCTAssertNil(refused, "the extension page must not load in a tab that may not run extensions")
        // webView.url may still name the address WebKit failed to load, so
        // what the document holds is what counts.
        let title = await evaluate(agent, "document.title")
        XCTAssertNotEqual(title as? String, "extension page")
        let api = await evaluate(agent, "typeof chrome !== 'undefined' && chrome.runtime ? 'api' : null")
        XCTAssertTrue(api == nil || api is NSNull, "no extension API in the agent tab")
    }
}
