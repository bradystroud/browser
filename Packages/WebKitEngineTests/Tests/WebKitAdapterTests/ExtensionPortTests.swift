import WebKit
import XCTest
@testable import WebKitAdapter

/// Extension message ports against real WebKit: `connectNative` hosts and
/// the background content they keep alive, and `runtime.connect` delivery
/// to extension pages.
@available(macOS 15.4, *)
@MainActor
final class ExtensionPortTests: XCTestCase {
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
    private var hostFolder: URL!
    private var profileId: String!
    private var savedInterval: TimeInterval = 0
    private var savedDirectories: [URL] = []
    private var window: NSWindow?

    private static let hostName = "com.example.porttest"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("brw-port-tests-\(UUID().uuidString)", isDirectory: true)
        hostFolder = root.appendingPathComponent("hosts", isDirectory: true)
        try FileManager.default.createDirectory(at: hostFolder, withIntermediateDirectories: true)
        host = FakeHost()
        let root = root!
        manager.activate(host: host, storageDirectory: { id in
            id.hasPrefix("private-") ? nil : root.appendingPathComponent(id).appendingPathComponent("Extensions", isDirectory: true)
        })
        profileId = UUID().uuidString
        savedInterval = WebKitNativeMessaging.keepAliveInterval
        savedDirectories = WebKitNativeMessaging.hostDirectories
        WebKitNativeMessaging.hostDirectories = [hostFolder]
    }

    override func tearDown() async throws {
        manager.unloadProfile(profileId: profileId)
        WebKitNativeMessaging.keepAliveInterval = savedInterval
        WebKitNativeMessaging.hostDirectories = savedDirectories
        window?.orderOut(nil)
        window = nil
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// Installs a store-style extension with the given files and grants, and
    /// loads it.
    private func install(id: String, manifest: [String: Any], files: [String: String], grants: [String]) async throws -> WKWebExtensionContext {
        let extensions = root.appendingPathComponent(profileId).appendingPathComponent("Extensions", isDirectory: true)
        let folder = extensions.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        for (name, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(name))
        }
        let record = InstalledWebExtension(id: id, source: .webStore, name: manifest["name"] as? String ?? id, version: "1.0", grants: grants)
        try InstalledWebExtensionList(extensions: [record]).save(to: extensions.appendingPathComponent("installed.json"))
        manager.loadExtensions(profileId: profileId)
        let loaded = await waitUntil(10) { manager.profile(for: profileId)?.contexts[id] != nil }
        XCTAssertTrue(loaded, "extension \(id) never loaded")
        return try XCTUnwrap(manager.profile(for: profileId)?.contexts[id])
    }

    /// A host that answers every message with `{"echo": <message>}` and
    /// otherwise waits for its input to close.
    private func writeEchoHost(origin: String) throws {
        let script = """
        #!/usr/bin/perl
        use strict; binmode STDIN; binmode STDOUT; $| = 1;
        while (1) {
          my $h; last if read(STDIN, $h, 4) != 4;
          my $n = unpack("L", $h); my $b = ''; read(STDIN, $b, $n);
          my $r = '{"echo":' . $b . '}';
          print pack("L", length($r)) . $r;
        }
        """
        let path = hostFolder.appendingPathComponent("echo-host")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        let manifest: [String: Any] = ["name": Self.hostName, "description": "test", "path": path.path, "type": "stdio", "allowed_origins": [origin]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: hostFolder.appendingPathComponent(Self.hostName + ".json"))
    }

    /// An MV3 worker that opens a native port at its top level, says hello
    /// once, and shows on its badge a token chosen when it started and
    /// whether the host answered. It never posts again, so WebKit sees no
    /// port activity from it after the first second.
    private func installNativePortExtension(id: String) async throws -> WKWebExtensionContext {
        try writeEchoHost(origin: "chrome-extension://\(id)/")
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Native Port", "version": "1.0",
            "permissions": ["nativeMessaging"],
            "background": ["service_worker": "background.js"],
            "action": ["default_title": "Native Port"],
        ]
        let worker = """
        const token = Math.random().toString(36).slice(2, 6);
        const port = chrome.runtime.connectNative("\(Self.hostName)");
        port.onMessage.addListener(function (m) {
          if (m && m.echo === "hello") chrome.action.setBadgeText({ text: token });
        });
        port.postMessage("hello");
        """
        return try await install(id: id, manifest: manifest, files: ["background.js": worker], grants: ["perm:nativeMessaging"])
    }

    private func badge(of id: String) -> String {
        manager.action(extensionId: id, profileId: profileId, tab: nil)?.badgeText ?? ""
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    private func isRunning(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    private func backgroundWebView(of context: WKWebExtensionContext) -> WKWebView? {
        let selector = NSSelectorFromString("_backgroundWebView")
        guard context.responds(to: selector) else { return nil }
        return context.perform(selector)?.takeUnretainedValue() as? WKWebView
    }

    /// Starts the native port extension and waits until the host answered.
    private func startNativePortExtension(id: String) async throws -> (WKWebExtensionContext, Int32) {
        let context = try await installNativePortExtension(id: id)
        let answered = await waitUntil(15) { !badge(of: id).isEmpty }
        XCTAssertTrue(answered, "the worker never heard back from its host; errors: \(context.errors)")
        let pids = WebKitNativeMessaging.hostProcessIdentifiers(for: context)
        XCTAssertEqual(pids.count, 1)
        return (context, try XCTUnwrap(pids.first))
    }

    // MARK: - Native hosts end with their extension

    func testDisablingAnExtensionStopsItsNativeHost() async throws {
        let id = String(repeating: "d", count: 32)
        let (_, pid) = try await startNativePortExtension(id: id)
        XCTAssertTrue(isRunning(pid))

        manager.setEnabled(false, extensionId: id, profileId: profileId)

        let ended = await waitUntil(5) { !isRunning(pid) }
        XCTAssertTrue(ended, "host \(pid) outlived its extension")
    }

    /// WebKit unloads the background content of a context whose worker's
    /// process ends. Its host must end with it, and the keep-alive must not
    /// wake the worker again.
    func testHostStopsWhenItsBackgroundContentGoesAway() async throws {
        WebKitNativeMessaging.keepAliveInterval = 0.5
        let id = String(repeating: "e", count: 32)
        let (context, pid) = try await startNativePortExtension(id: id)
        let background = try XCTUnwrap(backgroundWebView(of: context), "needs the _backgroundWebView SPI")
        let process = background._webProcessIdentifierForTesting
        XCTAssertGreaterThan(process, 0)

        kill(process, SIGKILL)

        let ended = await waitUntil(10) { !isRunning(pid) }
        XCTAssertTrue(ended, "host \(pid) outlived the background content it was started for")
        XCTAssertTrue(WebKitNativeMessaging.hostProcessIdentifiers(for: context).isEmpty)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertNil(backgroundWebView(of: context), "the keep-alive woke a worker that was not running")
    }

    // MARK: - The keep-alive (slow: WebKit's real timeouts)

    /// WebKit unloads background content 30 seconds after it was woken,
    /// unless its page posted on a port in the last two minutes, so an idle
    /// worker goes after about 120-150 seconds. These take that long, and
    /// only run with BRW_SLOW_TESTS=1.
    private func requireSlowTests() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BRW_SLOW_TESTS"] == "1", "set BRW_SLOW_TESTS=1 to wait out WebKit's real unload timeout")
    }

    func testOpenNativePortKeepsTheWorkerPastWebKitsIdleUnload() async throws {
        try requireSlowTests()
        let id = String(repeating: "f", count: 32)
        let (context, pid) = try await startNativePortExtension(id: id)
        let background = try XCTUnwrap(backgroundWebView(of: context))
        let token = badge(of: id)

        try await Task.sleep(nanoseconds: 200_000_000_000)

        XCTAssertTrue(backgroundWebView(of: context) === background, "the worker was unloaded or restarted")
        XCTAssertEqual(badge(of: id), token, "the worker started again")
        XCTAssertEqual(WebKitNativeMessaging.hostProcessIdentifiers(for: context), [pid])
        XCTAssertTrue(isRunning(pid))
    }

    /// The control for the test above: with the keep-alive slower than
    /// WebKit's timer, the idle worker is unloaded, and its host goes too.
    func testWithoutTheKeepAliveWebKitUnloadsTheIdleWorker() async throws {
        try requireSlowTests()
        WebKitNativeMessaging.keepAliveInterval = 400
        let id = String(repeating: "g", count: 32)
        let (context, pid) = try await startNativePortExtension(id: id)
        let started = Date()

        let unloaded = await waitUntil(200) { backgroundWebView(of: context) == nil }
        XCTAssertTrue(unloaded, "WebKit kept an idle worker for 200 seconds")
        print("WebKit unloaded the idle worker after \(Int(Date().timeIntervalSince(started))) s")
        let ended = await waitUntil(5) { !isRunning(pid) }
        XCTAssertTrue(ended, "host \(pid) outlived the unloaded worker")
    }

    // MARK: - runtime.connect between extension pages (a WebKit bug)

    /// WebKit queues a message posted on a `runtime.connect` port before the
    /// other end has connected, and when both ends are extension pages (the
    /// main world: background, popup, options, a tab) it delivers that queue
    /// twice: `WebExtensionContext::runtimeConnect` flushes the queue for the
    /// target world and then for the source world, which are the same queue.
    /// This holds both ways: what the page posts straight after `connect`,
    /// and what the background posts inside `onConnect`. A message posted
    /// once the port is connected arrives once. Content scripts are not
    /// affected (their world differs from the background's).
    ///
    /// The worker answers every message with how many it has had; the page
    /// posts "early" straight after connecting and "late" a second later.
    private static let connectFiles = [
        "background.js": """
        var count = 0;
        chrome.runtime.onConnect.addListener(function (port) {
          port.postMessage("hello");
          port.onMessage.addListener(function (m) { count += 1; port.postMessage(m + " " + count); });
        });
        """,
        "page.js": """
        window.received = [];
        const port = chrome.runtime.connect({ name: "test" });
        port.onMessage.addListener(function (m) { window.received.push(m); });
        port.postMessage("early");
        setTimeout(function () { port.postMessage("late"); }, 1000);
        """,
        "page.html": "<!doctype html><title>page</title><script src=\"page.js\"></script>",
    ]

    private static let connectManifest: [String: Any] = [
        "manifest_version": 3, "name": "Connect", "version": "1.0",
        "background": ["service_worker": "background.js"],
        "action": ["default_title": "Connect", "default_popup": "page.html"],
    ]

    /// What WebKit delivers today. When WebKit fixes the bug these become
    /// ["hello", "early 1", "late 2"], and the AGENTS.md note goes.
    private static let deliveredByWebKit = ["hello", "hello", "early 1", "early 2", "late 3"]

    private func received(in webView: WKWebView) async -> [String] {
        let deadline = Date().addingTimeInterval(10)
        var last: [String] = []
        while Date() < deadline {
            last = ((try? await webView.evaluateJavaScript("window.received || []")) as? [String]) ?? []
            if last.contains(where: { $0.hasPrefix("late") }) { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        return ((try? await webView.evaluateJavaScript("window.received || []")) as? [String]) ?? last
    }

    private func show(_ webView: WKWebView) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        webView.frame = window.contentView?.bounds ?? .zero
        window.orderBack(nil)
        self.window = window
    }

    /// An extension page in a tab, built the way the app builds one
    /// (`configuration(for:profileId:initialURL:)`).
    func testExtensionPageInATabSeesWebKitsDoubledQueue() async throws {
        let id = String(repeating: "h", count: 32)
        _ = try await install(id: id, manifest: Self.connectManifest, files: Self.connectFiles, grants: [])
        let url = "chrome-extension://\(id)/page.html"
        let configuration = manager.configuration(for: WKWebViewConfiguration(), profileId: profileId, initialURL: url)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        show(webView)
        webView.load(URLRequest(url: try XCTUnwrap(URL(string: url))))

        let got = await received(in: webView)
        XCTAssertEqual(got, Self.deliveredByWebKit)
    }

    /// WebKit's own action popup, which the app only shows.
    func testActionPopupSeesWebKitsDoubledQueue() async throws {
        let id = String(repeating: "i", count: 32)
        let context = try await install(id: id, manifest: Self.connectManifest, files: Self.connectFiles, grants: [])
        let popup = try XCTUnwrap(context.action(for: nil)?.popupWebView, "WebKit made no popup web view")
        show(popup)

        let got = await received(in: popup)
        XCTAssertEqual(got, Self.deliveredByWebKit)
    }

    /// The same with none of the app's code: a bare controller and context.
    func testBareWebKitDoublesTheQueueToo() async throws {
        let folder = root.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: Self.connectManifest).write(to: folder.appendingPathComponent("manifest.json"))
        for (name, text) in Self.connectFiles { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        try controller.load(context)
        defer { try? controller.unload(context) }
        let popup = try XCTUnwrap(context.action(for: nil)?.popupWebView)
        show(popup)

        let got = await received(in: popup)
        XCTAssertEqual(got, Self.deliveredByWebKit)
    }
}

private extension WKWebView {
    /// `_webProcessIdentifier`, private: the web content process behind the view.
    var _webProcessIdentifierForTesting: pid_t {
        guard responds(to: NSSelectorFromString("_webProcessIdentifier")) else { return 0 }
        return (value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value ?? 0
    }
}
