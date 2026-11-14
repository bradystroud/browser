import JavaScriptCore
import XCTest
@testable import WebEngineCore

final class ChromeExtensionCompatibilityTests: XCTestCase {
    private var folder: URL!
    private let tag = "<script src=\"/__browser_chrome_compat.js\"></script>"

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Fixtures

    private func write(_ text: String, to path: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)
    }

    private func manifest() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any])
    }

    /// Every file under the folder and its exact bytes.
    private func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files[String(url.path.dropFirst(folder.path.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    /// Shaped like iCloud Passwords: an MV3 service worker asking for
    /// `privacy`, a popup and an options page with scripts, and a page with
    /// none.
    private func makeServiceWorkerExtension(type: String? = nil) throws {
        var background = #""service_worker": "background.js""#
        if let type { background += #", "type": "\#(type)""# }
        try write("""
        {
            "manifest_version": 3,
            "name": "Fixture",
            "version": "1.0",
            "permissions": ["privacy", "storage", "nativeMessaging"],
            "background": { \(background) },
            "action": { "default_popup": "page_popup.html" },
            "options_ui": { "page": "settings.html" }
        }
        """, to: "manifest.json")
        try write("chrome.privacy.services.passwordSavingEnabled.get({});\n", to: "background.js")
        try write("<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Popup</title></head>\n<body><div id=\"x\"></div>\n<script src=\"page_popup.js\"></script>\n</body></html>\n", to: "page_popup.html")
        try write("<html><head>\n<!-- <script src=\"old.js\"></script> -->\n<SCRIPT type=\"text/javascript\" src=\"settings.js\"></SCRIPT>\n</head></html>\n", to: "settings.html")
        try write("<html><body><p>Thanks to everyone.</p></body></html>\n", to: "acknowledgments.html")
    }

    // MARK: - When it applies

    func testAnExtensionThatNeedsNothingIsLeftByteForByte() throws {
        try write("""
        {"manifest_version": 3, "name": "Plain", "version": "1",
         "permissions": ["storage", "tabs"],
         "background": {"service_worker": "bg.js"},
         "action": {"default_popup": "popup.html"}}
        """, to: "manifest.json")
        try write("chrome.storage.local.get();", to: "bg.js")
        try write("<html><script src=\"popup.js\"></script></html>", to: "popup.html")
        let before = try snapshot()

        XCTAssertEqual(try ChromeExtensionCompatibility.prepare(folder: folder), [])
        XCTAssertEqual(try snapshot(), before)
        XCTAssertFalse(ChromeExtensionCompatibility.isNeeded(folder: folder))
    }

    func testOptionalOrHostPermissionsAloneDoNotCount() {
        XCTAssertFalse(ChromeExtensionCompatibility.isNeeded(manifest: ["optional_permissions": ["privacy"], "host_permissions": ["*://*/*"]]))
        XCTAssertTrue(ChromeExtensionCompatibility.isNeeded(manifest: ["permissions": ["webNavigation"]]))
        XCTAssertTrue(ChromeExtensionCompatibility.isNeeded(manifest: ["permissions": ["privacy"]]))
    }

    func testAnUnreadableManifestIsAnError() throws {
        try write("{ not json", to: "manifest.json")
        XCTAssertThrowsError(try ChromeExtensionCompatibility.prepare(folder: folder)) { error in
            XCTAssertEqual(error as? ChromeExtensionCompatibility.PreparationError, .unreadableManifest)
        }
    }

    // MARK: - Preparing

    func testClassicServiceWorkerIsWrappedAndPagesGetTheShimFirst() throws {
        try makeServiceWorkerExtension()
        let untouchedPage = try read("acknowledgments.html")

        let written = try ChromeExtensionCompatibility.prepare(folder: folder)

        XCTAssertEqual(Set(written), ["__browser_chrome_compat.js", "__browser_background.js", "manifest.json", "page_popup.html", "settings.html"])
        XCTAssertEqual(try read("__browser_chrome_compat.js"), ChromeExtensionCompatibility.shimSource)
        let background = try XCTUnwrap(manifest()["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, "__browser_background.js")
        XCTAssertTrue(try read("__browser_background.js").contains(#"importScripts("/__browser_chrome_compat.js", "/background.js");"#))
        XCTAssertEqual(try read("background.js"), "chrome.privacy.services.passwordSavingEnabled.get({});\n", "the extension's own worker is not edited")
        XCTAssertEqual(try manifest()["permissions"] as? [String], ["privacy", "storage", "nativeMessaging"], "nothing else in the manifest changes")

        XCTAssertEqual(try read("page_popup.html"),
                       "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>Popup</title></head>\n<body><div id=\"x\"></div>\n\(tag)<script src=\"page_popup.js\"></script>\n</body></html>\n")
        XCTAssertEqual(try read("settings.html"),
                       "<html><head>\n<!-- <script src=\"old.js\"></script> -->\n\(tag)<SCRIPT type=\"text/javascript\" src=\"settings.js\"></SCRIPT>\n</head></html>\n",
                       "a script inside a comment is not the first script, and the match ignores case")
        XCTAssertEqual(try read("acknowledgments.html"), untouchedPage, "a page with no script needs nothing")
    }

    func testPreparingTwiceChangesNothingTheSecondTime() throws {
        try makeServiceWorkerExtension()
        XCTAssertFalse(try ChromeExtensionCompatibility.prepare(folder: folder).isEmpty)
        let once = try snapshot()

        XCTAssertEqual(try ChromeExtensionCompatibility.prepare(folder: folder), [])
        XCTAssertEqual(try snapshot(), once)
    }

    func testAnOutdatedShimIsReplaced() throws {
        try makeServiceWorkerExtension()
        try ChromeExtensionCompatibility.prepare(folder: folder)
        try write("// an older shim\n", to: "__browser_chrome_compat.js")

        XCTAssertEqual(try ChromeExtensionCompatibility.prepare(folder: folder), ["__browser_chrome_compat.js"])
        XCTAssertEqual(try read("__browser_chrome_compat.js"), ChromeExtensionCompatibility.shimSource)
    }

    func testModuleWorkerImportsTheShimFirst() throws {
        try makeServiceWorkerExtension(type: "module")
        try ChromeExtensionCompatibility.prepare(folder: folder)

        let background = try XCTUnwrap(manifest()["background"] as? [String: Any])
        XCTAssertEqual(background["service_worker"] as? String, "__browser_background.js")
        XCTAssertEqual(background["type"] as? String, "module")
        let wrapper = try read("__browser_background.js")
        let shim = try XCTUnwrap(wrapper.range(of: #"import "/__browser_chrome_compat.js";"#))
        let original = try XCTUnwrap(wrapper.range(of: #"import "/background.js";"#))
        XCTAssertLessThan(shim.lowerBound, original.lowerBound)
        XCTAssertFalse(wrapper.contains("importScripts"))
    }

    func testWorkerInASubfolderKeepsItsPath() throws {
        try write(#"{"manifest_version": 3, "name": "N", "version": "1", "permissions": ["webNavigation"], "background": {"service_worker": "js/sw.js"}}"#, to: "manifest.json")
        try write("", to: "js/sw.js")
        try ChromeExtensionCompatibility.prepare(folder: folder)
        XCTAssertTrue(try read("__browser_background.js").contains(#"importScripts("/__browser_chrome_compat.js", "/js/sw.js");"#))
    }

    func testBackgroundScriptsGetTheShimFirst() throws {
        try write(#"{"manifest_version": 2, "name": "N", "version": "1", "permissions": ["privacy"], "background": {"scripts": ["a.js", "b.js"], "persistent": false}}"#, to: "manifest.json")
        try ChromeExtensionCompatibility.prepare(folder: folder)
        let background = try XCTUnwrap(manifest()["background"] as? [String: Any])
        XCTAssertEqual(background["scripts"] as? [String], ["__browser_chrome_compat.js", "a.js", "b.js"])
        XCTAssertEqual(background["persistent"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("__browser_background.js").path))
    }

    func testBackgroundPageAndNestedPagesGetTheRootRelativeTag() throws {
        try write(#"{"manifest_version": 2, "name": "N", "version": "1", "permissions": ["privacy"], "background": {"page": "bg/background.html"}}"#, to: "manifest.json")
        try write("<script src=\"bg.js\"></script>", to: "bg/background.html")
        let manifestBefore = try read("manifest.json")

        XCTAssertEqual(try ChromeExtensionCompatibility.prepare(folder: folder), ["__browser_chrome_compat.js", "bg/background.html"])
        XCTAssertEqual(try read("bg/background.html"), "\(tag)<script src=\"bg.js\"></script>")
        XCTAssertEqual(try read("manifest.json"), manifestBefore, "a background page needs no manifest change")
    }

    func testAFileUnderTheWorkerNameIsNotOverwritten() throws {
        try makeServiceWorkerExtension()
        try write("// the extension's own\n", to: "__browser_background.js")
        XCTAssertThrowsError(try ChromeExtensionCompatibility.prepare(folder: folder)) { error in
            XCTAssertEqual(error as? ChromeExtensionCompatibility.PreparationError, .nameTaken("__browser_background.js"))
        }
        XCTAssertEqual(try read("__browser_background.js"), "// the extension's own\n")
    }

    /// A preparation that stopped after writing the wrapper but before the
    /// manifest: the next one finishes the job instead of refusing forever.
    func testAWrapperLeftByAnInterruptedPreparationIsFinished() throws {
        try makeServiceWorkerExtension()
        let manifestBefore = try read("manifest.json")
        try write(ChromeExtensionCompatibility.workerSource(wrapping: "background.js", module: false), to: "__browser_background.js")

        let written = try ChromeExtensionCompatibility.prepare(folder: folder)
        XCTAssertTrue(written.contains("manifest.json"))
        XCTAssertFalse(written.contains("__browser_background.js"), "an identical wrapper is kept as it is")
        XCTAssertNotEqual(try read("manifest.json"), manifestBefore)
        XCTAssertEqual((try manifest()["background"] as? [String: Any])?["service_worker"] as? String, "__browser_background.js")
        XCTAssertEqual(try ChromeExtensionCompatibility.prepare(folder: folder), [])
    }

    func testAnOlderWrapperOfTheLayersIsRewritten() throws {
        try makeServiceWorkerExtension()
        try write(ChromeExtensionCompatibility.workerHeader + "importScripts(\"/elsewhere.js\");\n", to: "__browser_background.js")
        let written = try ChromeExtensionCompatibility.prepare(folder: folder)
        XCTAssertTrue(written.contains("__browser_background.js"))
        XCTAssertEqual(try read("__browser_background.js"), ChromeExtensionCompatibility.workerSource(wrapping: "background.js", module: false))
    }

    func testScriptLikeWordsAreNotScripts() {
        let page = Data("<html><scripts-list></scripts-list><noscript>x</noscript></html>".utf8)
        XCTAssertNil(ChromeExtensionCompatibility.insertingShim(into: page))
    }

    // MARK: - The shim itself, run in JavaScriptCore

    /// A stand-in for WebKit's `chrome` object: runtime, tabs.onReplaced
    /// that the test can fire, and the webNavigation events WebKit has.
    private func context(permissions: [String], extraSetup: String = "") throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JavaScript exception: \(exception?.toString() ?? "?")")
        }
        let list = String(data: try JSONSerialization.data(withJSONObject: permissions), encoding: .utf8)!
        context.evaluateScript("""
        var replacedListeners = [];
        var chrome = {
          runtime: { getManifest: function () { return { permissions: \(list) }; } },
          tabs: { onReplaced: { addListener: function (f) { replacedListeners.push(f); } } },
          webNavigation: { onCompleted: { addListener: function () {} } }
        };
        var log = [];
        \(extraSetup)
        """)
        context.evaluateScript(ChromeExtensionCompatibility.shimSource)
        return context
    }

    private func string(_ context: JSContext, _ script: String) -> String? {
        context.evaluateScript(script)?.toString()
    }

    func testShimSuppliesPrivacyAsUncontrollableSettings() throws {
        let js = try context(permissions: ["privacy"])
        js.evaluateScript("""
        chrome.privacy.services.passwordSavingEnabled.get({}).then(function (d) { log.push('promise:' + d.value + ':' + d.levelOfControl); });
        chrome.privacy.services.autofillAddressEnabled.get({}, function (d) { log.push('callback:' + d.levelOfControl); });
        log.push('after get');
        chrome.privacy.services.autofillCreditCardEnabled.set({ value: false }).then(
          function () { log.push('set resolved'); }, function (e) { log.push('set rejected'); });
        chrome.privacy.services.autofillCreditCardEnabled.clear({}).then(function () { log.push('clear resolved'); });
        """)
        XCTAssertEqual(string(js, "log.join('|')"),
                       "after get|promise:true:not_controllable|callback:not_controllable|set rejected|clear resolved",
                       "a callback runs after the call returns, as in Chrome")
        XCTAssertEqual(string(js, "typeof chrome.privacy.network + typeof chrome.privacy.websites"), "objectobject")
        XCTAssertEqual(string(js, """
        var listener = function () {};
        var change = chrome.privacy.services.passwordSavingEnabled.onChange;
        change.addListener(listener);
        var had = change.hasListener(listener);
        change.removeListener(listener);
        had + ',' + change.hasListener(listener);
        """), "true,false")
    }

    /// Apple's iCloud Passwords reads each setting through a helper that
    /// throws on `not_controllable` inside a try/catch, and then leaves the
    /// setting alone; this is that logic, and nothing may escape it.
    func testICloudPasswordsSettingsLogicGivesUpQuietly() throws {
        let js = try context(permissions: ["privacy"])
        js.evaluateScript("""
        async function read(setting) {
          if (!setting) throw new Error('Unable to get setting');
          const details = await setting.get({});
          if (details.levelOfControl === 'not_controllable') throw new Error('Cannot control setting');
          return details;
        }
        async function control(setting, wanted) {
          let details;
          try { details = await read(setting); } catch (e) { return; }
          log.push('tried to set');
        }
        const s = chrome.privacy.services;
        Promise.allSettled([control(s.passwordSavingEnabled, false), control(s.autofillCreditCardEnabled, false), control(s.autofillAddressEnabled, false)])
          .then(function (r) { log.push(r.map(function (x) { return x.status + ':' + x.value; }).join(',')); });
        """)
        XCTAssertEqual(string(js, "log.join('|')"), "fulfilled:undefined,fulfilled:undefined,fulfilled:undefined")
    }

    func testShimSuppliesMissingWebNavigationEventsAndBridgesTabReplacement() throws {
        let js = try context(permissions: ["webNavigation"])
        XCTAssertEqual(string(js, "typeof chrome.privacy"), "undefined", "privacy only for an extension that asked for it")
        XCTAssertEqual(string(js, "replacedListeners.length"), "0", "tabs.onReplaced is not listened to until someone listens")
        js.evaluateScript("""
        chrome.webNavigation.onHistoryStateUpdated.addListener(function () {});
        chrome.webNavigation.onReferenceFragmentUpdated.addListener(function () {});
        chrome.webNavigation.onCreatedNavigationTarget.addListener(function () {});
        chrome.webNavigation.onTabReplaced.addListener(function (d) { log.push(d.replacedTabId + '->' + d.tabId + ':' + typeof d.timeStamp); });
        replacedListeners.forEach(function (f) { f(7, 3); });
        """)
        XCTAssertEqual(string(js, "replacedListeners.length"), "1")
        XCTAssertEqual(string(js, "log.join('|')"), "3->7:number")
    }

    func testShimLeavesWhatTheEngineHasAlone() throws {
        let js = try context(permissions: ["privacy", "webNavigation"], extraSetup: """
        var own = { addListener: function () { log.push('engine event'); } };
        chrome.webNavigation.onHistoryStateUpdated = own;
        chrome.privacy = { services: { passwordSavingEnabled: 'engine' } };
        """)
        XCTAssertEqual(string(js, "chrome.webNavigation.onHistoryStateUpdated === own"), "true")
        XCTAssertEqual(string(js, "chrome.privacy.services.passwordSavingEnabled"), "engine")
        XCTAssertEqual(string(js, "typeof chrome.privacy.services.autofillAddressEnabled.get"), "function", "only the missing members are added")
    }

    func testShimDoesNothingWithoutAnExtensionAPI() throws {
        let js = try XCTUnwrap(JSContext())
        js.exceptionHandler = { _, exception in XCTFail("JavaScript exception: \(exception?.toString() ?? "?")") }
        js.evaluateScript(ChromeExtensionCompatibility.shimSource)
        XCTAssertEqual(js.evaluateScript("typeof chrome")?.toString(), "undefined", "a sandboxed page has no chrome object, and gets none")
    }
}
