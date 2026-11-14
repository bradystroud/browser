import JavaScriptCore
import XCTest
@testable import WebEngineCore

/// `chrome.privacy.services.passwordSavingEnabled` as a real setting, run in
/// JavaScriptCore against a stand-in for the engine's `runtime`: what the
/// shim asks the browser, what it does with the answers, and that without a
/// way to ask it stays `not_controllable` as before.
final class ChromeSettingsShimTests: XCTestCase {
    /// `answer` is JavaScript deciding the browser's reply to `message`;
    /// `failWith` makes every call fail the way a missing host does.
    private func context(permissions: [String], answer: String = "return null;", extraSetup: String = "") throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JavaScript exception: \(exception?.toString() ?? "?")")
        }
        let list = String(data: try JSONSerialization.data(withJSONObject: permissions), encoding: .utf8)!
        context.evaluateScript("""
        var requests = [];
        var ports = [];
        var log = [];
        var chrome = {
          runtime: {
            lastError: undefined,
            getManifest: function () { return { permissions: \(list) }; },
            sendNativeMessage: function (host, message, callback) {
              requests.push(host + ' ' + JSON.stringify(message));
              var reply = (function (message) { \(answer) })(message);
              Promise.resolve().then(function () {
                if (reply === null) { chrome.runtime.lastError = { message: 'Specified native messaging host not found.' }; }
                callback(reply === null ? undefined : reply);
                chrome.runtime.lastError = undefined;
              });
            },
            connectNative: function (host) {
              var listeners = [];
              var port = { host: host, onMessage: { addListener: function (f) { listeners.push(f); } },
                           deliver: function (m) { listeners.forEach(function (f) { f(m); }); } };
              ports.push(port);
              return port;
            }
          }
        };
        \(extraSetup)
        """)
        context.evaluateScript(ChromeExtensionCompatibility.shimSource)
        return context
    }

    private func string(_ context: JSContext, _ script: String) -> String? {
        context.evaluateScript(script)?.toString()
    }

    private let browserAnswers = """
        if (message.op === 'get') return { value: !window_held, levelOfControl: window_held ? 'controlled_by_this_extension' : 'controllable_by_this_extension' };
        if (message.op === 'set') { window_held = true; return { value: message.value, levelOfControl: 'controlled_by_this_extension' }; }
        if (message.op === 'clear') { window_held = false; return { value: true, levelOfControl: 'controllable_by_this_extension' }; }
        return { error: 'unknown' };
        """

    func testGetAsksTheBrowserOnTheReservedHost() throws {
        let js = try context(permissions: ["privacy", "nativeMessaging"], answer: browserAnswers, extraSetup: "var window_held = false;")
        js.evaluateScript("""
        chrome.privacy.services.passwordSavingEnabled.get({}).then(function (d) { log.push(d.value + ':' + d.levelOfControl); });
        """)
        XCTAssertEqual(string(js, "log.join('|')"), "true:controllable_by_this_extension")
        XCTAssertEqual(string(js, "requests.join('|')"), #"dev.stroud.browser.settings {"setting":"services.passwordSavingEnabled","op":"get"}"#)
        XCTAssertEqual(ChromeExtensionCompatibility.settingsHost, "dev.stroud.browser.settings")
    }

    /// iCloud Passwords' own logic: read, and when controllable and not
    /// already false, set it to false. Only the password setting is asked
    /// about; the card and address settings stay `not_controllable` and
    /// never reach the browser.
    func testICloudPasswordsTakesControlOfPasswordSavingOnly() throws {
        let js = try context(permissions: ["privacy", "nativeMessaging"], answer: browserAnswers, extraSetup: "var window_held = false;")
        js.evaluateScript("""
        async function read(setting) {
          const details = await setting.get({});
          if (details.levelOfControl === 'not_controllable') throw new Error('Cannot control');
          return details;
        }
        async function control(setting, wanted) {
          let details;
          try { details = await read(setting); } catch (e) { return 'gave up'; }
          if (details.value === wanted) return 'already';
          try { await setting.set({ value: wanted }); } catch (e) { return 'refused'; }
          return 'set';
        }
        const s = chrome.privacy.services;
        Promise.allSettled([control(s.passwordSavingEnabled, false), control(s.autofillCreditCardEnabled, false), control(s.autofillAddressEnabled, false)])
          .then(function (r) { log.push(r.map(function (x) { return x.value; }).join(',')); });
        """)
        XCTAssertEqual(string(js, "log.join('|')"), "set,gave up,gave up")
        XCTAssertEqual(string(js, "requests.map(function (r) { return JSON.parse(r.slice(r.indexOf(' ') + 1)).op; }).join(',')"), "get,set")
        XCTAssertEqual(string(js, "window_held"), "true")
    }

    func testCallbackFormAndClear() throws {
        let js = try context(permissions: ["privacy", "nativeMessaging"], answer: browserAnswers, extraSetup: "var window_held = true;")
        js.evaluateScript("""
        var setting = chrome.privacy.services.passwordSavingEnabled;
        setting.get({}, function (d) { log.push('get:' + d.levelOfControl); });
        log.push('returned');
        setting.clear({}, function () { log.push('cleared'); });
        """)
        XCTAssertEqual(string(js, "log.join('|')"), "returned|get:controlled_by_this_extension|cleared")
        XCTAssertEqual(string(js, "window_held"), "false")
    }

    func testARefusalRejectsTheSet() throws {
        let js = try context(permissions: ["privacy", "nativeMessaging"],
                             answer: "return { error: 'Another extension controls this setting.' };")
        js.evaluateScript("""
        chrome.privacy.services.passwordSavingEnabled.set({ value: false }).then(
          function () { log.push('resolved'); }, function (e) { log.push('rejected: ' + e.message); });
        chrome.privacy.services.passwordSavingEnabled.set({ value: 'no' }).then(
          function () { log.push('resolved'); }, function (e) { log.push('bad value'); });
        """)
        XCTAssertEqual(string(js, "log.join('|')"), "bad value|rejected: Another extension controls this setting.")
        XCTAssertEqual(string(js, "requests.length"), "1", "a non-boolean value never reaches the browser")
    }

    /// No answer from the browser -- an engine or build without the host --
    /// is what the shim did before the setting was real.
    func testNoAnswerFallsBackToNotControllable() throws {
        let js = try context(permissions: ["privacy", "nativeMessaging"], answer: "return null;")
        js.evaluateScript("""
        var s = chrome.privacy.services.passwordSavingEnabled;
        s.get({}).then(function (d) { log.push(d.value + ':' + d.levelOfControl); });
        s.set({ value: false }).then(function () { log.push('set'); }, function () { log.push('set refused'); });
        s.clear({}).then(function () { log.push('cleared'); });
        """)
        XCTAssertEqual(string(js, "log.join('|')"), "true:not_controllable|set refused|cleared")
    }

    func testWithoutNativeMessagingNothingIsAsked() throws {
        let js = try context(permissions: ["privacy"], answer: browserAnswers, extraSetup: "var window_held = false;")
        js.evaluateScript("""
        chrome.privacy.services.passwordSavingEnabled.get({}).then(function (d) { log.push(d.levelOfControl); });
        chrome.privacy.services.passwordSavingEnabled.onChange.addListener(function () {});
        """)
        XCTAssertEqual(string(js, "log.join('|')"), "not_controllable")
        XCTAssertEqual(string(js, "requests.length + ports.length"), "0")
    }

    func testChangesArriveOnOnePortOpenedOnlyOnceSomeoneListens() throws {
        let js = try context(permissions: ["privacy", "nativeMessaging"], answer: browserAnswers, extraSetup: "var window_held = false;")
        XCTAssertEqual(string(js, "ports.length"), "0", "nothing is opened until a listener is added")
        js.evaluateScript("""
        var change = chrome.privacy.services.passwordSavingEnabled.onChange;
        change.addListener(function (d) { log.push('a:' + d.value + ':' + d.levelOfControl); });
        change.addListener(function (d) { log.push('b:' + d.value); });
        ports[0].deliver({ setting: 'services.passwordSavingEnabled', value: false, levelOfControl: 'controlled_by_other_extensions' });
        ports[0].deliver({ setting: 'services.somethingElse', value: true, levelOfControl: 'controllable_by_this_extension' });
        ports[0].deliver('garbage');
        """)
        XCTAssertEqual(string(js, "ports.length + ' ' + ports[0].host"), "1 dev.stroud.browser.settings")
        XCTAssertEqual(string(js, "log.join('|')"), "a:false:controlled_by_other_extensions|b:false")
    }

    /// A page framed inside a web page (iCloud Passwords' in-page list) runs
    /// in that page's process: it may read the setting and listen to it, but
    /// taking or releasing it is refused before anything is sent.
    func testAFramedPageMayReadButNotChangeTheSetting() throws {
        let js = try context(permissions: ["privacy", "nativeMessaging"], answer: browserAnswers, extraSetup: """
        var window_held = false;
        var location = { origin: "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj", pathname: "/completion_list.html" };
        var window = { top: { location: { origin: "https://site.test" } } };
        """)
        js.evaluateScript("""
        var s = chrome.privacy.services.passwordSavingEnabled;
        s.get({}).then(function (d) { log.push('get ' + d.levelOfControl); });
        s.set({ value: false }).then(function () { log.push('set'); }, function (e) { log.push('set refused: ' + e.message); });
        s.clear({}, function () { log.push('clear called back'); });
        s.onChange.addListener(function () {});
        """)
        XCTAssertEqual(string(js, "log.join('|')"),
                       "set refused: An extension page shown inside a web page can read this setting but not change it.|clear called back|get controllable_by_this_extension")
        XCTAssertEqual(string(js, "requests.map(function (r) { return JSON.parse(r.slice(r.indexOf(' ') + 1)).op; }).join(',')"), "get")
        XCTAssertEqual(string(js, "ports.length + ' ' + window_held"), "1 false")
    }

    /// Another engine reaches the browser its own way and says so before
    /// the shim runs; the requests are the same.
    func testAnEngineMaySupplyItsOwnTransport() throws {
        let js = try context(permissions: ["privacy"], extraSetup: """
        globalThis.__browserSettingsTransport = {
          request: function (message) { log.push('custom ' + message.op); return Promise.resolve({ value: false, levelOfControl: 'controlled_by_this_extension' }); }
        };
        """)
        js.evaluateScript("""
        chrome.privacy.services.passwordSavingEnabled.get({}).then(function (d) { log.push(d.value + ':' + d.levelOfControl); });
        """)
        XCTAssertEqual(string(js, "log.join('|')"), "custom get|false:controlled_by_this_extension")
        XCTAssertEqual(string(js, "requests.length"), "0")
    }
}
