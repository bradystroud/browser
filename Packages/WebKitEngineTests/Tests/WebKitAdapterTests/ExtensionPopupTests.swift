import WebKit
import XCTest
@testable import WebKitAdapter

/// An extension's popup reached three ways, against real WebKit: the toolbar
/// button, `action.openPopup()` from a click in the extension's own frame
/// inside a web page, and that frame's `window.open` of an extension page
/// as a popup window. The extension mirrors how iCloud Passwords asks the
/// user to pair: a content script shows a web-accessible page as an iframe,
/// and a click there opens the popup, which connects to its worker at once.
@available(macOS 15.4, *)
@MainActor
final class ExtensionPopupTests: XCTestCase {
    private final class FakeTab: ExtensionHostTab {
        let engineTab: WebKitTab
        weak var window: FakeWindow?
        init(_ tab: WebKitTab) { engineTab = tab }
        var extensionEngineTab: EngineTab? { engineTab }
        var extensionTitle: String { engineTab.webView.title ?? "" }
        var extensionURL: URL? { engineTab.webView.url }
        var extensionIsLoading: Bool { engineTab.webView.isLoading }
        var extensionIsPinned: Bool { false }
        var extensionWindow: ExtensionHostWindow? { window }
        func extensionLoad(_ url: URL) { engineTab.webView.load(URLRequest(url: url)) }
        func extensionActivate() {}
        func extensionClose() {}
        func extensionSetPinned(_ pinned: Bool) {}
    }

    private final class FakeWindow: ExtensionHostWindow {
        let profileId: String
        let nsWindow: NSWindow
        let anchor: NSView
        var tabs: [FakeTab] = []
        init(profileId: String, nsWindow: NSWindow, anchor: NSView) {
            self.profileId = profileId
            self.nsWindow = nsWindow
            self.anchor = anchor
        }
        var extensionProfileId: String { profileId }
        var extensionTabs: [ExtensionHostTab] { tabs }
        var extensionActiveTab: ExtensionHostTab? { tabs.first }
        var extensionNSWindow: NSWindow? { nsWindow }
        func extensionOpenTab(url: URL?, active: Bool) -> ExtensionHostTab? { nil }
        func extensionClose() {}
        func extensionPopupAnchor(forExtension id: String) -> NSView? { anchor }
    }

    private final class FakeHost: ExtensionHost {
        var windows: [FakeWindow] = []
        func extensionWindows(profileId: String) -> [ExtensionHostWindow] { windows.filter { $0.profileId == profileId } }
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
    private var nsWindow: NSWindow!
    private var tab: WebKitTab!
    private var recorder: RecordingTabDelegate!
    private let id = String(repeating: "k", count: 32)

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brw-popup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        host = FakeHost()
        let root = root!
        manager.activate(host: host, storageDirectory: { id in
            id.hasPrefix("private-") ? nil : root.appendingPathComponent(id).appendingPathComponent("Extensions", isDirectory: true)
        })
        profileId = UUID().uuidString
        server = try LocalHTTPServer(routes: [
            "/login": .html("<!doctype html><title>login</title><body style='margin:0'><input type=password id=pw style='margin-top:200px'><script>window.events=[];addEventListener('message',e=>window.events.push(e.data));</script></body>"),
        ])
        try server.start()
    }

    override func tearDown() async throws {
        tab?.close()
        tab = nil
        nsWindow?.close()
        nsWindow = nil
        manager.unloadProfile(profileId: profileId)
        server?.stop()
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private static let files: [String: String] = [
        "background.js": """
        self.connects = 0;
        chrome.runtime.onConnect.addListener(function (port) {
          self.connects += 1;
          port.onMessage.addListener(function (m) { if (m === "ping") port.postMessage("pong " + self.connects); });
        });
        """,
        "content.js": """
        if (window === window.top) {
          const frame = document.createElement("iframe");
          frame.src = chrome.runtime.getURL("list.html?screenX=0&screenY=0&effectiveWindowWidth=800" + (location.search.indexOf("direct") >= 0 ? "&direct=1" : ""));
          frame.style.cssText = "position:fixed;left:0;top:0;width:300px;height:100px;border:0";
          document.body.appendChild(frame);
        }
        """,
        "list.html": "<!doctype html><body style='margin:0'><button id=b style='width:300px;height:100px'>Enable</button><script src=list.js></script></body>",
        "list.js": """
        function tell(m) { window.top.postMessage(m, "*"); }
        tell("list ready");
        function openWindow() {
          const w = window.open(chrome.runtime.getURL("popup.html?popupWindow=1"), null,
            "popup, width=378, innerHeight=150, left=0, top=0, scrollbars=no, resizable=no, location=no, toolbar=no");
          tell("window.open returned " + (w ? "a window" : "null"));
        }
        document.getElementById("b").addEventListener("click", async function () {
          tell("clicked");
          if (location.search.indexOf("direct=1") >= 0) { openWindow(); return; }
          try {
            await chrome.action.openPopup();
            tell("openPopup resolved");
          } catch (e) {
            tell("openPopup rejected: " + e.message);
            openWindow();
          }
        });
        """,
        "popup.html": "<!doctype html><title>popup</title><body><p id=state>loading</p><script src=popup.js></script></body>",
        "popup.js": """
        const port = chrome.runtime.connect({ name: "popup" });
        port.onMessage.addListener(function (m) {
          document.getElementById("state").textContent = m;
          document.title = m;
          if (window.popupWindow) setTimeout(function () { window.close(); }, 300);
        });
        setTimeout(function () { port.postMessage("ping"); }, 300);
        if (new URLSearchParams(location.search).get("popupWindow") === "1") window.popupWindow = true;
        """,
    ]

    private static let manifest: [String: Any] = [
        "manifest_version": 3, "name": "Popup Path", "version": "1.0",
        "background": ["service_worker": "background.js"],
        "action": ["default_title": "Popup Path", "default_popup": "popup.html"],
        "host_permissions": ["http://127.0.0.1/*"],
        "content_scripts": [["matches": ["http://127.0.0.1/*"], "js": ["content.js"], "run_at": "document_idle"]],
        "web_accessible_resources": [["resources": ["list.html"], "matches": ["<all_urls>"]]],
    ]

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func pageEvents() -> [String] {
        var result: [String] = []
        var done = false
        tab.webView.evaluateJavaScript("window.events || []") { value, _ in
            result = value as? [String] ?? []
            done = true
        }
        _ = waitUntil(5) { done }
        return result
    }

    /// Installs the extension, opens a tab in a reported window, and loads
    /// the sign-in page until the extension's frame says it is ready.
    private func openSignInPage(path: String = "/login", unpacked: Bool = false, manifest: [String: Any] = ExtensionPopupTests.manifest,
                                files: [String: String] = ExtensionPopupTests.files, grants: [String] = ["host:http://127.0.0.1/*"]) throws -> FakeWindow {
        let extensions = root.appendingPathComponent(profileId).appendingPathComponent("Extensions", isDirectory: true)
        let folder = unpacked ? root.appendingPathComponent("dev-popup-path", isDirectory: true) : extensions.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        let record = InstalledWebExtension(id: id, source: unpacked ? .unpacked : .webStore, name: "Popup Path", version: "1.0",
                                           unpackedPath: unpacked ? folder.path : nil, grants: grants)
        try FileManager.default.createDirectory(at: extensions, withIntermediateDirectories: true)
        try InstalledWebExtensionList(extensions: [record]).save(to: extensions.appendingPathComponent("installed.json"))
        manager.loadExtensions(profileId: profileId)
        XCTAssertTrue(waitUntil(10) { manager.profile(for: profileId)?.contexts[id] != nil }, "extension never loaded")

        nsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        nsWindow.isReleasedWhenClosed = false
        let content = try XCTUnwrap(nsWindow.contentView)
        let anchor = NSView(frame: NSRect(x: 760, y: 560, width: 20, height: 20))
        content.addSubview(anchor)
        tab = try XCTUnwrap(WebKitEngine.createTab(profileName: "Test", profileId: profileId, hostView: content, initialURL: "", runsExtensions: true) as? WebKitTab)
        recorder = RecordingTabDelegate()
        tab.delegate = recorder
        let window = FakeWindow(profileId: profileId, nsWindow: nsWindow, anchor: anchor)
        let fakeTab = FakeTab(tab)
        fakeTab.window = window
        window.tabs = [fakeTab]
        host.windows = [window]
        manager.windowDidOpen(window)
        manager.tabDidOpen(fakeTab)
        manager.tabDidActivate(fakeTab, previous: nil)
        manager.windowDidBecomeFocused(window)

        tab.loadURL(server.url(path))
        XCTAssertTrue(waitUntil(10) { pageEvents().contains("list ready") }, "the extension's frame never loaded: \(pageEvents())")
        return window
    }

    /// A click whose page process dies under it never reports back, so the
    /// control below does not wait for one.
    private func clickTheFrame(waitForCompletion: Bool = true) throws {
        let automation = try XCTUnwrap(tab.automation)
        var done = false
        automation.click(at: CGPoint(x: 50, y: 50), clickCount: 1) { _ in done = true }
        if waitForCompletion { XCTAssertTrue(waitUntil(5) { done }) }
    }

    private var terminations: [Notification] = []

    private func watchForTermination() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .engineTabContentProcessDidTerminate, object: nil, queue: nil) { [weak self] note in
            MainActor.assumeIsolated { self?.terminations.append(note) }
        }
    }

    private func title(of webView: WKWebView?) -> String { webView?.title ?? "" }

    /// What iCloud Passwords' "Enable Password AutoFill" does: a click in its
    /// frame awaits action.openPopup(). Unhelped, WebKit kills the page's
    /// web content process for it (the frame shares the page's process, which
    /// may not send privileged messages); the compatibility layer relays it
    /// through the worker, and the real popup opens and connects.
    func testOpenPopupFromAFramedPageOpensThePopupAndKeepsThePage() throws {
        let observer = watchForTermination()
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try openSignInPage()
        try clickTheFrame()

        XCTAssertTrue(waitUntil(5) { pageEvents().contains { $0.hasPrefix("openPopup") } }, "events: \(pageEvents())")
        XCTAssertTrue(pageEvents().contains("openPopup resolved"), "events: \(pageEvents())")
        let profile = try XCTUnwrap(manager.profile(for: profileId))
        XCTAssertTrue(waitUntil(5) { profile.shownPopoverExtensionId == id }, "the popup was never presented")
        let popup = profile.contexts[id]?.action(for: nil)?.popupWebView
        XCTAssertTrue(waitUntil(5) { title(of: popup).hasPrefix("pong") }, "the popup never heard from its worker: \(title(of: popup))")
        XCTAssertTrue(terminations.isEmpty, "the page's web content process was killed")
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("commit:") }.count, 1, "the page reloaded")
        XCTAssertTrue(WebKitExtensionPageWindow.open.isEmpty)
    }

    /// The control: without the compatibility layer (an unpacked extension is
    /// loaded as it is), the same click kills the page's web content process.
    func testWithoutTheLayerOpenPopupFromAFramedPageKillsThePage() throws {
        let observer = watchForTermination()
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try openSignInPage(unpacked: true)
        try clickTheFrame(waitForCompletion: false)

        XCTAssertTrue(waitUntil(5) { !terminations.isEmpty }, "WebKit no longer kills the page; the relay in ChromeExtensionCompatibility may be unneeded")
    }

    /// An extension frame's window.open of its own page with popup features,
    /// straight from a click, opens in a small window built from the
    /// extension's configuration; the page renders, connects to its worker
    /// and closes itself.
    func testWindowOpenOfItsOwnPageShowsASmallWindowThatCanClose() throws {
        let observer = watchForTermination()
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = try openSignInPage(path: "/login?direct")
        try clickTheFrame()

        XCTAssertTrue(waitUntil(5) { pageEvents().contains { $0.hasPrefix("window.open") } }, "events: \(pageEvents())")
        let opened = try XCTUnwrap(WebKitExtensionPageWindow.open.first, "no extension page window opened; events: \(pageEvents())")
        XCTAssertEqual(opened.webView.url?.absoluteString, "chrome-extension://\(id)/popup.html?popupWindow=1")
        XCTAssertEqual(opened.panel.contentRect(forFrameRect: opened.panel.frame).size, CGSize(width: 378, height: 150))
        XCTAssertTrue(waitUntil(5) { title(of: opened.webView).hasPrefix("pong") }, "the page window never rendered and connected")
        XCTAssertTrue(waitUntil(5) { WebKitExtensionPageWindow.open.isEmpty }, "the page could not close its own window")
        XCTAssertFalse(opened.panel.isVisible)
        XCTAssertTrue(recorder.popups.isEmpty, "the extension page must not become a popup tab of the web page")
        XCTAssertTrue(terminations.isEmpty, "the page's web content process was killed")
    }

    /// iCloud Passwords' own fallback runs window.open only after an awaited
    /// openPopup() has rejected. By then WebKit no longer counts the click as
    /// a user gesture, and its popup blocker drops the call before the app
    /// hears of it: window.open returns null and nothing opens. Nothing breaks
    /// either. This pins that, so a WebKit change shows up here.
    func testFallbackAfterARejectedOpenPopupIsBlockedByWebKit() throws {
        let observer = watchForTermination()
        defer { NotificationCenter.default.removeObserver(observer) }
        let window = try openSignInPage()
        manager.windowDidClose(window)
        try clickTheFrame()

        XCTAssertTrue(waitUntil(5) { pageEvents().contains { $0.hasPrefix("window.open") } }, "events: \(pageEvents())")
        XCTAssertTrue(pageEvents().contains { $0.hasPrefix("openPopup rejected") }, "events: \(pageEvents())")
        XCTAssertTrue(pageEvents().contains("window.open returned null"), "events: \(pageEvents())")
        XCTAssertTrue(WebKitExtensionPageWindow.open.isEmpty)
        XCTAssertTrue(terminations.isEmpty, "the page's web content process was killed")
    }

    // MARK: - Other APIs from a framed page

    /// A frame that does what iCloud Passwords' completion list can do --
    /// read and change passwordSavingEnabled and listen for its changes,
    /// use storage and a runtime port -- and also calls two privileged APIs.
    /// It starts when clicked and reports each outcome to the page.
    private static let probeFiles: [String: String] = {
        var files = ExtensionPopupTests.files
        files["list.js"] = """
        function tell(m) { window.top.postMessage(m, "*"); }
        function outcome(label, promise) {
          return Promise.resolve(promise).then(function (v) { tell(label + " ok " + JSON.stringify(v === undefined ? null : v)); },
                                               function (e) { tell(label + " failed " + e.message); });
        }
        tell("list ready");
        document.getElementById("b").addEventListener("click", function () {
          const setting = chrome.privacy.services.passwordSavingEnabled;
          setting.onChange.addListener(function () {});
          const port = chrome.runtime.connect({ name: "probe" });
          port.onMessage.addListener(function (m) { tell("port " + m); });
          port.postMessage("ping");
          let threw = "no";
          try { chrome.tabs.connect(1); } catch (e) { threw = e.message; }
          tell("tabs.connect threw " + threw);
          Promise.all([
            outcome("privacy.get", setting.get({}).then(function (d) { return d.levelOfControl; })),
            outcome("privacy.set", setting.set({ value: false })),
            outcome("storage", chrome.storage.local.set({ a: 1 }).then(function () { return chrome.storage.local.get("a"); })),
            outcome("tabs.query", chrome.tabs.query({})),
            outcome("alarms.getAll", chrome.alarms.getAll())
          ]).then(function () { tell("probe done"); });
        });
        """
        return files
    }()

    private static let probeManifest: [String: Any] = {
        var manifest = ExtensionPopupTests.manifest
        manifest["permissions"] = ["privacy", "nativeMessaging", "storage", "alarms", "tabs"]
        return manifest
    }()

    private static let probeGrants = ["host:http://127.0.0.1/*", "perm:privacy", "perm:nativeMessaging", "perm:storage", "perm:alarms", "perm:tabs"]

    /// Native messaging and storage are not privileged in WebKit, so the
    /// settings transport works from a framed page as it is; tabs and alarms
    /// are, and the layer refuses them there instead of letting WebKit kill
    /// the page.
    /// The browser's settings, as the app answers them: get only, recorded.
    private final class RecordingProvider: ExtensionSettingsProvider {
        var requests: [String] = []
        var subscriptions = 0
        func handle(_ request: Any, from extensionId: String, profileId: String) -> [String: Any] {
            requests.append("\((request as? [String: Any])?["op"] as? String ?? "?") from \(extensionId)")
            return ["value": true, "levelOfControl": "controllable_by_this_extension"]
        }
        func subscribe(extensionId: String, profileId: String, send: @escaping ([String: Any]) -> Void) -> NSObjectProtocol {
            subscriptions += 1
            return NSObject()
        }
        func unsubscribe(_ token: NSObjectProtocol) {}
        func release(extensionId: String, profileId: String) {}
        func forget(profileId: String) {}
    }

    func testAFramedPageCanUseSettingsStorageAndPortsAndIsRefusedPrivilegedAPIs() throws {
        let observer = watchForTermination()
        defer { NotificationCenter.default.removeObserver(observer) }
        let provider = RecordingProvider()
        ExtensionSettingsHost.provider = provider
        defer { ExtensionSettingsHost.provider = nil }
        _ = try openSignInPage(manifest: Self.probeManifest, files: Self.probeFiles, grants: Self.probeGrants)
        try clickTheFrame()

        XCTAssertTrue(waitUntil(10) { pageEvents().contains("probe done") }, "events: \(pageEvents())")
        _ = waitUntil(1) { pageEvents().contains { $0.hasPrefix("port ") } }
        let events = Set(pageEvents())
        // The frame reads the setting through the browser's own host, which
        // answers in-app, and may listen to it; it may not change it.
        XCTAssertTrue(events.contains("privacy.get ok \"controllable_by_this_extension\""), "\(events)")
        XCTAssertTrue(events.contains("privacy.set failed An extension page shown inside a web page can read this setting but not change it."), "\(events)")
        XCTAssertEqual(provider.requests, ["get from \(id)"])
        XCTAssertTrue(waitUntil(5) { provider.subscriptions == 1 }, "the frame's onChange listener reached the browser")
        let context = try XCTUnwrap(manager.profile(for: profileId)?.contexts[id])
        XCTAssertEqual(WebKitNativeMessaging.settingsPortCount(for: context), 1)
        XCTAssertTrue(WebKitNativeMessaging.hostProcessIdentifiers(for: context).isEmpty, "no host process stands behind it")
        XCTAssertTrue(events.contains("storage ok {\"a\":1}"), "\(events)")
        XCTAssertTrue(events.contains { $0.hasPrefix("port pong") }, "\(events)")
        XCTAssertTrue(events.contains("tabs.query failed chrome.tabs.query() is not available in an extension page shown inside a web page."), "\(events)")
        XCTAssertTrue(events.contains("alarms.getAll failed chrome.alarms.getAll() is not available in an extension page shown inside a web page."), "\(events)")
        XCTAssertTrue(events.contains("tabs.connect threw chrome.tabs.connect() is not available in an extension page shown inside a web page."), "\(events)")
        settle(1)
        XCTAssertTrue(terminations.isEmpty, "the page's web content process was killed")
        XCTAssertEqual(recorder.events.filter { $0.hasPrefix("commit:") }.count, 1, "the page reloaded")
    }

    /// The control for the guard: loaded as it is, the same frame's
    /// tabs.query kills the page.
    func testWithoutTheLayerAPrivilegedAPIFromAFramedPageKillsThePage() throws {
        let observer = watchForTermination()
        defer { NotificationCenter.default.removeObserver(observer) }
        var files = Self.files
        files["list.js"] = """
        window.top.postMessage("list ready", "*");
        document.getElementById("b").addEventListener("click", function () { chrome.tabs.query({}); });
        """
        var manifest = Self.manifest
        manifest["permissions"] = ["tabs"]
        _ = try openSignInPage(unpacked: true, manifest: manifest, files: files, grants: ["host:http://127.0.0.1/*", "perm:tabs"])
        try clickTheFrame(waitForCompletion: false)

        XCTAssertTrue(waitUntil(5) { !terminations.isEmpty }, "WebKit no longer kills the page for tabs.query; the guard may be unneeded")
    }

    private func settle(_ seconds: TimeInterval) { _ = waitUntil(seconds) { false } }

    /// A web page cannot use the same path to open an extension's page.
    func testAWebPageCannotOpenAnExtensionPageWindow() throws {
        _ = try openSignInPage()
        let url = try XCTUnwrap(URL(string: "chrome-extension://\(id)/popup.html"))
        XCTAssertFalse(manager.openPageWindow(url, openerOrigin: nil, from: tab.webView, features: WKWindowFeatures()))
        XCTAssertFalse(manager.openPageWindow(url, openerOrigin: "chrome-extension://\(String(repeating: "z", count: 32))", from: tab.webView, features: WKWindowFeatures()))
        XCTAssertTrue(WebKitExtensionPageWindow.open.isEmpty)
    }

    /// The toolbar button: WebKit's own popover, whose page connects to the
    /// worker as it loads.
    func testToolbarButtonPopupRendersAndConnects() throws {
        let window = try openSignInPage()
        manager.performAction(extensionId: id, window: window)
        let profile = try XCTUnwrap(manager.profile(for: profileId))
        XCTAssertTrue(waitUntil(5) { profile.shownPopoverExtensionId == id }, "the popup was never presented")
        let popup = profile.contexts[id]?.action(for: nil)?.popupWebView
        XCTAssertTrue(waitUntil(5) { title(of: popup).hasPrefix("pong") }, "the popup never heard from its worker: \(title(of: popup))")
    }
}
