import JavaScriptCore
import XCTest
@testable import WebEngineCore

final class CEFExtensionShimTests: XCTestCase {
    private let marker = "Symbol.for('brw.cefShim')"

    /// A stand-in for Chromium's bindings: every method that matters logs
    /// `NATIVE ...` if the real one is reached, and `fetch` records what is
    /// posted and answers with `fetchReply`.
    private func context(withFetch: Bool = true, extraSetup: String = "") throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in
            XCTFail("JavaScript exception: \(exception?.toString() ?? "?")")
        }
        context.evaluateScript("""
        var log = [];
        var fetchCalls = [];
        var timers = [];
        var updateCalls = [];
        var fetchReply = '{}';
        var fetchMode = 'reply';
        function setTimeout(f, ms) { f.ms = ms; timers.push(f); return timers.length; }
        function clearTimeout() {}
        function URL(url, base) { this.href = /^[a-z-]+:/i.test(url) ? url : base + url.replace(/^\\//, ''); }
        \(withFetch ? """
        function fetch(url, init) {
          fetchCalls.push({ url: url, method: init.method, body: init.body, credentials: init.credentials });
          if (fetchMode === 'reject') return Promise.reject(new Error('network'));
          if (fetchMode === 'hang') return new Promise(function () {});
          return Promise.resolve({ ok: fetchMode !== 'error', text: function () { return Promise.resolve(fetchReply); } });
        }
        """ : "")
        var chrome = {
          runtime: {
            getManifest: function () { return { options_ui: { page: 'options.html' } }; },
            getURL: function (p) { return 'chrome-extension://abc/' + String(p).replace(/^\\//, ''); },
            openOptionsPage: function () { log.push('NATIVE openOptionsPage'); },
            reload: function () { log.push('NATIVE reload'); }
          },
          tabs: {
            create: function () { log.push('NATIVE tabs.create'); },
            update: function () { updateCalls.push(Array.prototype.slice.call(arguments)); return Promise.resolve({ id: 1 }); },
            discard: function () { log.push('NATIVE tabs.discard'); }
          },
          action: { openPopup: function () { log.push('NATIVE openPopup'); } },
          management: { uninstallSelf: function () { log.push('NATIVE uninstallSelf'); } },
          permissions: { contains: function (r) { log.push('contains:' + JSON.stringify(r)); return Promise.resolve(!!(r && r.permissions && r.permissions[0] === 'storage')); }, request: function () { log.push('NATIVE permissions.request'); } },
          windows: { create: function () { log.push('NATIVE windows.create'); } },
          identity: { launchWebAuthFlow: function () { log.push('NATIVE launchWebAuthFlow'); } }
        };
        function Clients() {}
        Clients.prototype.openWindow = function () { log.push('NATIVE openWindow'); };
        var originalTabs = chrome.tabs;
        \(extraSetup)
        """)
        context.evaluateScript(CEFExtensionShim.source)
        return context
    }

    private func string(_ context: JSContext, _ script: String) -> String? {
        context.evaluateScript(script)?.toString()
    }

    private func log(_ context: JSContext) -> String? { string(context, "log.join('|')") }

    func testEveryReplacementCarriesTheMarkerAndNothingNativeStays() throws {
        let js = try context()
        for path in ["chrome.tabs.create", "chrome.tabs.update", "chrome.tabs.discard", "chrome.windows.create",
                     "chrome.runtime.openOptionsPage", "chrome.runtime.reload", "chrome.permissions.request", "chrome.action.openPopup", "chrome.identity.launchWebAuthFlow", "Clients.prototype.openWindow"] {
            XCTAssertEqual(string(js, "(\(path))[\(marker)]"), "true", path)
        }
    }

    func testMethodsAreLockedAndNamespacesAreLeftAlone() throws {
        let js = try context(extraSetup: "")
        XCTAssertEqual(string(js, "(chrome.runtime.openOptionsPage)[\(marker)]"), "true")
        XCTAssertEqual(string(js, "chrome.tabs === originalTabs"), "true", "the namespace object is patched, never replaced")
        XCTAssertEqual(string(js, """
        var d = Object.getOwnPropertyDescriptor(chrome.tabs, 'create');
        [d.writable, d.configurable, delete chrome.tabs.create, (chrome.tabs.create)[\(marker)]].join(',')
        """), "false,false,false,true")
        XCTAssertEqual(string(js, "var before = chrome.tabs.create; chrome.tabs.create = function () {}; chrome.tabs.create === before"), "true")
    }

    func testTabsCreateAnswersLikeChromeInBothForms() throws {
        let js = try context()
        js.evaluateScript("""
        fetchReply = '{"tab":{"id":42,"windowId":7,"evil":"x","title":{"nested":1}}}';
        var returned = chrome.tabs.create({ url: 'page.html', active: false });
        returned.then(function (tab) { log.push('promise:' + tab.id + ':' + tab.windowId + ':' + tab.pendingUrl + ':' + tab.evil + ':' + typeof tab.title); });
        var viaCallback = chrome.tabs.create({ url: 'https://example.com/' }, function (tab) { log.push('callback:' + tab.pendingUrl + ':' + tab.id); });
        log.push('returned:' + (returned instanceof Promise) + ',' + viaCallback);
        """)
        XCTAssertEqual(log(js),
                       "returned:true,undefined|promise:42:7:chrome-extension://abc/page.html:undefined:undefined|callback:https://example.com/:42",
                       "a callback runs after the call returns; only plain values of known keys come from the reply")
        XCTAssertEqual(string(js, "fetchCalls[0].url"), "https://extension-bridge.browser.invalid/v1/tabs.create")
        XCTAssertEqual(string(js, "fetchCalls[0].method + ',' + fetchCalls[0].credentials"), "POST,omit")
        XCTAssertEqual(string(js, "JSON.stringify(JSON.parse(fetchCalls[0].body).detail)"), #"{"active":false,"url":"chrome-extension://abc/page.html"}"#)
        XCTAssertEqual(string(js, "JSON.parse(fetchCalls[0].body).kind + ':' + JSON.parse(fetchCalls[0].body).version"), "tabs.create:\(CEFExtensionShim.version)")
        XCTAssertEqual(string(js, "chrome.tabs.create({}).then(function (t) { log.push('empty:' + t.pendingUrl); }); 'ok'"), "ok")
        XCTAssertEqual(string(js, "JSON.stringify(JSON.parse(fetchCalls[fetchCalls.length - 1].body).detail)"), "{}")
    }

    func testAnAppThatRefusesOrDoesNotAnswerMakesTheCallFailLikeChromeAndNeverThrows() throws {
        for mode in ["reject", "hang", "error"] {
            let js = try context(extraSetup: "fetchMode = '\(mode)';")
            js.evaluateScript("""
            chrome.tabs.create({ url: 'https://a.example/' }).then(function () { log.push('resolved'); }, function (e) { log.push('rejected:' + e.message); });
            chrome.tabs.create({ url: 'https://a.example/' }, function (t) { log.push('cb:' + t + ':' + chrome.runtime.lastError.message); });
            chrome.windows.create({ url: 'https://a.example/' }).then(function () { log.push('resolved'); }, function (e) { log.push('rejected:' + e.message); });
            chrome.windows.create({}, function (w) { log.push('wcb:' + w + ':' + chrome.runtime.lastError.message); });
            chrome.runtime.openOptionsPage().then(function () { log.push('resolved'); }, function (e) { log.push('rejected:' + e.message); });
            """)
            if mode == "hang" {
                XCTAssertEqual(log(js), "", "no answer yet")
                js.evaluateScript("timers.forEach(function (f) { f(); });")
            }
            XCTAssertEqual(log(js), "rejected:No current window|cb:undefined:No current window|rejected:Could not create window.|wcb:undefined:Could not create window.|rejected:Could not create an options page.", mode)
        }
        let okButNotJSON = try context(extraSetup: "fetchReply = 'not json';")
        okButNotJSON.evaluateScript("chrome.tabs.create({ url: 'https://a.example/' }).then(function (t) { log.push('ok:' + t.id + ':' + t.pendingUrl); });")
        XCTAssertEqual(log(okButNotJSON), "ok:-1:https://a.example/", "an answer that succeeded without a body is still an answer")
        let noFetch = try context(withFetch: false)
        noFetch.evaluateScript("chrome.windows.create({ url: 'https://a.example/' }).then(function () { log.push('resolved'); }, function (e) { log.push('rejected:' + e.message); });")
        XCTAssertEqual(log(noFetch), "rejected:Could not create window.", "a page with no fetch cannot reach the app")
    }

    func testWindowsCreateTakesOneUrlManyUrlsOrNone() throws {
        let js = try context()
        js.evaluateScript("""
        fetchReply = '{"window":{"id":9,"focused":false}}';
        chrome.windows.create({ url: ['https://a.example/', 'b.html'], type: 'popup', width: 300 }, function (w) { log.push('cb:' + w.id + ':' + w.focused + ':' + w.tabs.map(function (t) { return t.pendingUrl; }).join(',')); });
        chrome.windows.create(function (w) { log.push('bare:' + w.tabs.length); });
        """)
        XCTAssertEqual(log(js), "cb:9:false:https://a.example/,chrome-extension://abc/b.html|bare:1")
        XCTAssertEqual(string(js, "JSON.stringify(JSON.parse(fetchCalls[0].body).detail)"),
                       #"{"type":"popup","width":300,"url":["https://a.example/","chrome-extension://abc/b.html"]}"#)
    }

    func testOpenOptionsPageForwardsTheOptionsUrlAndRejectsWithoutOne() throws {
        let js = try context()
        js.evaluateScript("""
        chrome.runtime.openOptionsPage().then(function (v) { log.push('opened:' + v); });
        chrome.runtime.openOptionsPage(function () { log.push('cb:' + arguments.length); });
        """)
        XCTAssertEqual(log(js), "opened:undefined|cb:0")
        XCTAssertEqual(string(js, "JSON.parse(fetchCalls[0].body).kind + ' ' + JSON.parse(fetchCalls[0].body).detail.url"),
                       "runtime.openOptionsPage chrome-extension://abc/options.html")

        let none = try context(extraSetup: "chrome.runtime.getManifest = function () { return {}; };")
        none.evaluateScript("""
        chrome.runtime.openOptionsPage().catch(function (e) { log.push(e.message); });
        chrome.runtime.openOptionsPage(function () { log.push('lastError:' + chrome.runtime.lastError.message); });
        """)
        XCTAssertEqual(log(none), "Could not create an options page.|lastError:Could not create an options page.")
        XCTAssertEqual(string(none, "fetchCalls.length"), "0")
        XCTAssertEqual(string(none, "typeof chrome.runtime.lastError"), "undefined", "lastError is only there while the callback runs")
    }

    func testOnlyAnInteractiveWebAuthFlowIsReplaced() throws {
        let js = try context()
        js.evaluateScript("""
        chrome.identity.launchWebAuthFlow({ url: 'https://auth.example/', interactive: true }).catch(function (e) { log.push('rejected:' + e.message); });
        chrome.identity.launchWebAuthFlow({ url: 'https://auth.example/', interactive: true }, function (r) { log.push('cb:' + r + ':' + chrome.runtime.lastError.message); });
        """)
        XCTAssertEqual(log(js), "rejected:Authorization page could not be loaded.|cb:undefined:Authorization page could not be loaded.")
        XCTAssertEqual(string(js, "fetchCalls.length"), "2")
        js.evaluateScript("log.length = 0; chrome.identity.launchWebAuthFlow({ url: 'https://auth.example/', interactive: false }, function () {}); chrome.identity.launchWebAuthFlow({ url: 'x' });")
        XCTAssertEqual(log(js), "NATIVE launchWebAuthFlow|NATIVE launchWebAuthFlow", "the silent form is Chromium's own")
        XCTAssertEqual(string(js, "fetchCalls.length"), "2")
        XCTAssertEqual(string(js, "(chrome.identity.launchWebAuthFlow)[\(marker)]"), "true")
    }

    func testUninstallSelfNeverReachesChromium() throws {
        let js = try context()
        js.evaluateScript("""
        chrome.management.uninstallSelf({ showConfirmDialog: true, junk: 1 }).catch(function (e) { log.push('rejected:' + e.message); });
        chrome.management.uninstallSelf(function () { log.push('cb:' + chrome.runtime.lastError.message); });
        """)
        XCTAssertEqual(log(js), "rejected:User cancelled uninstall|cb:User cancelled uninstall")
        XCTAssertEqual(string(js, "fetchCalls[0].url + ' ' + JSON.stringify(JSON.parse(fetchCalls[0].body).detail)"),
                       #"https://extension-bridge.browser.invalid/v1/management.uninstallSelf {"showConfirmDialog":true}"#)
        XCTAssertEqual(string(js, "(chrome.management.uninstallSelf)[\(marker)]"), "true")
    }

    func testEveryRequestCarriesTheCopysTokenWhenThereIsOne() throws {
        let js = try context(extraSetup: "globalThis[Symbol.for('brw.cefInfo')] = { token: 'abc123' };")
        js.evaluateScript("chrome.tabs.create({}); chrome.runtime.reload(); chrome.windows.create({});")
        XCTAssertEqual(string(js, "fetchCalls.map(function (c) { return JSON.parse(c.body).token; }).join(',')"), "abc123,abc123,abc123")
        let none = try context()
        none.evaluateScript("chrome.runtime.reload();")
        XCTAssertEqual(string(none, "'token' in JSON.parse(fetchCalls[0].body)"), "false")
    }

    func testTabsUpdateAcceptsAnOmittedTabId() throws {
        let js = try context()
        js.evaluateScript("""
        chrome.tabs.update(undefined, { url: 'https://a.example/', autoDiscardable: true });
        chrome.tabs.update(null, { muted: true, openerTabId: 3 }, function () {});
        chrome.tabs.update({ url: 'https://b.example/' }, function () {});
        """)
        XCTAssertEqual(string(js, "updateCalls.map(function (c) { return String(c[0] === undefined ? 'u' : c[0] === null ? 'n' : 'o') + ':' + (typeof c[1]) + ':' + (typeof c[2]); }).join(',')"),
                       "u:object:undefined,n:object:function,o:function:undefined")
        XCTAssertEqual(string(js, "Object.keys(updateCalls[0][1]).join(',') + '|' + Object.keys(updateCalls[1][1]).join(',')"), "url|muted")
    }

    func testTabsDiscardRejectsAsChromeDoes() throws {
        let js = try context()
        js.evaluateScript("""
        chrome.tabs.discard(5).catch(function (e) { log.push(e.message); });
        chrome.tabs.discard(6, function (t) { log.push('cb:' + t + ':' + chrome.runtime.lastError.message); });
        chrome.tabs.discard().catch(function (e) { log.push(e.message); });
        """)
        XCTAssertEqual(log(js), "Cannot discard tab with id: 5.|cb:undefined:Cannot discard tab with id: 6.|Cannot find a tab to discard.")
    }

    func testTabsUpdateOnlyPassesTheDocumentedSafeKeys() throws {
        let js = try context()
        js.evaluateScript("""
        var asked = [];
        var spy = new Proxy({ url: 'https://a.example/', autoDiscardable: false }, {
          get: function (t, k) { asked.push(String(k)); return k === 'autoDiscardable' ? false : t[k]; },
          has: function () { return true; }
        });
        var r1 = chrome.tabs.update(3, { url: 'https://a.example/', autoDiscardable: false, openerTabId: 4, muted: true, pinned: true, active: true, highlighted: false, selected: true });
        chrome.tabs.update({ autoDiscardable: true, openerTabId: 2, url: 'https://b.example/' }, function () {});
        chrome.tabs.update(7, spy);
        chrome.tabs.update(8, { openerTabId: 1 }, function () {});
        """)
        XCTAssertEqual(string(js, "Object.keys(updateCalls[0][1]).sort().join(',')"), "active,highlighted,muted,pinned,selected,url")
        XCTAssertEqual(string(js, "updateCalls[0][0]"), "3")
        XCTAssertEqual(string(js, "r1 instanceof Promise"), "true", "the original's return value comes back")
        XCTAssertEqual(string(js, "Object.keys(updateCalls[1][0]).join(',') + ':' + typeof updateCalls[1][1]"), "url:function")
        XCTAssertEqual(string(js, "Object.keys(updateCalls[2][1]).join(',')"), "url")
        XCTAssertEqual(string(js, "asked.filter(function (k) { return k === 'autoDiscardable' || k === 'openerTabId'; }).length"), "0",
                       "the dangerous keys are never even read")
        XCTAssertEqual(string(js, "Object.keys(updateCalls[3][1]).length + ':' + typeof updateCalls[3][2]"), "0:function")
        XCTAssertEqual(string(js, "updateCalls.length"), "4")
    }

    func testRuntimeReloadStaysAwayFromChromiumAndTellsTheApp() throws {
        let js = try context()
        js.evaluateScript("var r = chrome.runtime.reload(); log.push('returned:' + r);")
        XCTAssertEqual(log(js), "returned:undefined")
        XCTAssertEqual(string(js, "JSON.parse(fetchCalls[0].body).kind"), "runtime.reload")
        XCTAssertEqual(string(js, "fetchCalls[0].url"), "https://extension-bridge.browser.invalid/v1/runtime.reload")
    }

    func testActionOpenPopupResolvesOnAnswerAndRejectsOtherwise() throws {
        let js = try context()
        js.evaluateScript("""
        chrome.action.openPopup({ windowId: 4, junk: 1 }).then(function (v) { log.push('opened:' + v); }, function (e) { log.push('rejected:' + e.message); });
        chrome.action.openPopup(function () { log.push('cb:' + arguments.length + ':' + chrome.runtime.lastError); });
        """)
        XCTAssertEqual(log(js), "opened:undefined|cb:0:undefined")
        XCTAssertEqual(string(js, "JSON.stringify(JSON.parse(fetchCalls[0].body).detail) + ' ' + JSON.parse(fetchCalls[0].body).kind"), #"{"windowId":4} action.openPopup"#)

        for mode in ["error", "reject", "hang"] {
            let failing = try context(extraSetup: "fetchMode = '\(mode)';")
            failing.evaluateScript("""
            chrome.action.openPopup().then(function () { log.push('opened'); }, function (e) { log.push('rejected:' + e.message); });
            chrome.action.openPopup(function () { log.push('cb:' + chrome.runtime.lastError.message); });
            """)
            if mode == "hang" { failing.evaluateScript("timers.forEach(function (f) { f(); });") }
            XCTAssertEqual(log(failing), "rejected:Failed to open popup.|cb:Failed to open popup.", mode)
        }
    }

    func testClientsOpenWindowNeverReachesChromium() throws {
        let js = try context()
        js.evaluateScript("new Clients().openWindow('https://a.example/').then(function (v) { log.push('client:' + v); });")
        XCTAssertEqual(log(js), "client:null")
        XCTAssertEqual(string(js, "JSON.parse(fetchCalls[0].body).kind"), "clients.openWindow")
    }

    func testBrowserNamespaceIsPatchedWhenItIsAnotherObject() throws {
        let js = try context(extraSetup: """
        var browser = { runtime: chrome.runtime, tabs: { create: function () { log.push('NATIVE browser.tabs.create'); } } };
        """)
        js.evaluateScript("browser.tabs.create({ url: 'https://a.example/' });")
        XCTAssertEqual(string(js, "(browser.tabs.create)[\(marker)]"), "true")
        XCTAssertEqual(log(js), "")
    }

    func testRunningTwiceChangesNothing() throws {
        let js = try context()
        js.evaluateScript("var first = chrome.tabs.create; var marked = Object.getOwnPropertyDescriptor(globalThis, Symbol.for('brw.cefShim')).value;")
        js.evaluateScript(CEFExtensionShim.source)
        XCTAssertEqual(string(js, "chrome.tabs.create === first"), "true")
        XCTAssertEqual(string(js, "globalThis[\(marker)].version"), "\(CEFExtensionShim.version)")
        XCTAssertEqual(string(js, "Object.keys(globalThis[\(marker)].status).length > 5"), "true")
    }

    func testAPageWithNoExtensionAPIGetsNothingAndNothingBreaks() throws {
        let js = try XCTUnwrap(JSContext())
        js.exceptionHandler = { _, exception in XCTFail("JavaScript exception: \(exception?.toString() ?? "?")") }
        js.evaluateScript(CEFExtensionShim.source)
        XCTAssertEqual(js.evaluateScript("typeof chrome")?.toString(), "undefined")
    }

    func testTheShimNamesMatchWhatThePreparerWritesAndTheBridgeExpects() {
        XCTAssertEqual(CEFExtensionShim.fileName, "brw-cef-shim.v\(CEFExtensionShim.version).js")
        XCTAssertEqual(CEFExtensionShim.workerFileName(storeVersion: "1"), "brw-background.v\(CEFExtensionShim.version)-1.js")
        XCTAssertEqual(CEFExtensionShim.bridgeURL(kind: "tabs.create"), "https://extension-bridge.browser.invalid/v1/tabs.create")
        XCTAssertEqual(CEFExtensionShim.bridgeHostPermission, "https://extension-bridge.browser.invalid/*")
        XCTAssertFalse(CEFExtensionShim.fileName.hasPrefix("_") || CEFExtensionShim.workerFileName(storeVersion: "1").hasPrefix("_"))
        XCTAssertTrue(CEFExtensionShim.source.contains("https://extension-bridge.browser.invalid/v1/"))
        XCTAssertFalse(CEFExtensionShim.source.contains("\\#("), "every interpolation was made")
    }

    // MARK: - Lifecycle events, activation and the store's version

    /// A worker: it has `addEventListener`, a runtime whose `onInstalled` and
    /// `onStartup` are Chromium's stand-ins, and the info the preparer writes
    /// ahead of the shim.
    private func worker(added: Bool = true, extraSetup: String = "") throws -> JSContext {
        try context(extraSetup: """
        var swListeners = {};
        function addEventListener(type, f) { swListeners[type] = f; }
        globalThis[Symbol.for('brw.cefInfo')] = { storeVersion: '1.0', preparedVersion: '1.0.2', addedVersionName: \(added) };
        function realEvent(name) { return { name: name, added: [], addListener: function (f) { this.added.push(f); } }; }
        var realInstalled = realEvent('onInstalled');
        var realStartup = realEvent('onStartup');
        chrome.runtime.onInstalled = realInstalled;
        chrome.runtime.onStartup = realStartup;
        chrome.runtime.getManifest = function () { return { name: 'x', version: '1.0.2', version_name: '1.0' }; };
        function startNow() { var due = timers.filter(function (f) { return f.ms === 0; }); timers = timers.filter(function (f) { return f.ms !== 0; }); due.forEach(function (f) { f(); }); }
        function bodies() { return fetchCalls.map(function (c) { return JSON.parse(c.body); }); }
        \(extraSetup)
        """)
    }

    func testTheExtensionSeesTheStoresVersionInWorkerAndPages() throws {
        let js = try worker()
        XCTAssertEqual(string(js, "var m = chrome.runtime.getManifest(); [m.version, 'version_name' in m, m.name].join(',')"), "1.0,false,x")
        XCTAssertEqual(string(js, "(chrome.runtime.getManifest)[\(marker)]"), "true")

        let own = try worker(added: false)
        XCTAssertEqual(string(own, "var m = chrome.runtime.getManifest(); [m.version, m.version_name].join(',')"), "1.0,1.0", "a version_name the store published stays")

        let page = try context(extraSetup: """
        globalThis[Symbol.for('brw.cefInfo')] = { storeVersion: '3.1', preparedVersion: '3.1.2', addedVersionName: true };
        chrome.runtime.getManifest = function () { return { version: '3.1.2', version_name: '3.1' }; };
        """)
        XCTAssertEqual(string(page, "var m = chrome.runtime.getManifest(); [m.version, 'version_name' in m].join(',')"), "3.1,false")
        let plain = try context()
        XCTAssertEqual(string(plain, "(chrome.runtime.getManifest)[\(marker)]"), "undefined", "with no info the manifest is left alone")
    }

    func testTheExtensionsLifecycleListenersNeverReachChromium() throws {
        let js = try worker()
        XCTAssertEqual(string(js, "realInstalled.added.length + ',' + realStartup.added.length"), "1,1", "one listener of the shim's own keeps the worker waking")
        js.evaluateScript("""
        var a = function () { log.push('a'); }, b = function () { log.push('b'); };
        chrome.runtime.onInstalled.addListener(a);
        chrome.runtime.onInstalled.addListener(a);
        chrome.runtime.onInstalled.addListener(b);
        chrome.runtime.onStartup.addListener(a);
        """)
        XCTAssertEqual(string(js, "realInstalled.added.length + ',' + realStartup.added.length"), "1,1", "the extension's listeners are kept off the real event")
        XCTAssertEqual(string(js, "[chrome.runtime.onInstalled.hasListener(a), chrome.runtime.onInstalled.hasListeners(), chrome.runtime.onStartup.hasListener(b)].join(',')"), "true,true,false")
        XCTAssertEqual(string(js, "(chrome.runtime.onInstalled)[\(marker)] + ',' + (chrome.runtime.onInstalled !== realInstalled)"), "true,true")
        XCTAssertEqual(string(js, "Object.getOwnPropertyDescriptor(chrome.runtime, 'onInstalled').configurable"), "false")
        XCTAssertEqual(string(js, "realInstalled.added[0]({ reason: 'install' }); realStartup.added[0](); log.join('|')"), "", "what Chromium sends reaches no extension listener")
        XCTAssertEqual(string(js, "chrome.runtime.onInstalled.removeListener(a); chrome.runtime.onInstalled.removeListener(function () {}); chrome.runtime.onInstalled.hasListener(a)"), "false")
        XCTAssertEqual(string(js, "try { chrome.runtime.onInstalled.addListener(5); 'no throw'; } catch (e) { e instanceof TypeError; }"), "true")
    }

    func testWorkerStartedIsPostedOnceAfterTopLevelCodeEvenWithoutListeners() throws {
        let js = try worker()
        XCTAssertEqual(string(js, "fetchCalls.length"), "0", "nothing before the extension's own code has run")
        js.evaluateScript("startNow(); startNow();")
        XCTAssertEqual(string(js, "fetchCalls.length"), "1")
        XCTAssertEqual(string(js, "fetchCalls[0].url"), "https://extension-bridge.browser.invalid/v1/worker.started")
        XCTAssertEqual(string(js, "JSON.stringify(bodies()[0].detail)"), #"{"shimVersion":\#(CEFExtensionShim.version),"storeVersion":"1.0","preparedVersion":"1.0.2"}"#)
    }

    func testWhatTheAppSaysIsDueIsDeliveredInChromesOrderAndReported() throws {
        let js = try worker(extraSetup: "fetchReply = '{\"onStartup\":true,\"onInstalled\":{\"reason\":\"update\",\"previousVersion\":\"0.9\"}}';")
        js.evaluateScript("""
        chrome.runtime.onStartup.addListener(function () { log.push('startup:' + arguments.length); });
        chrome.runtime.onInstalled.addListener(function (d) { log.push('installed:' + d.reason + ':' + d.previousVersion); });
        chrome.runtime.onInstalled.addListener(function () { throw new Error('one listener breaks'); });
        chrome.runtime.onInstalled.addListener(function (d) { log.push('installed2:' + Object.keys(d).join('+')); });
        """)
        js.evaluateScript("startNow();")
        XCTAssertEqual(log(js), "installed:update:0.9|installed2:reason+previousVersion|startup:0", "onInstalled first, a throwing listener does not stop the rest")
        XCTAssertEqual(string(js, "bodies().map(function (b) { return b.kind; }).join(',')"), "worker.started,lifecycle.delivered")
        XCTAssertEqual(string(js, "var d = bodies()[1].detail; [d.shimVersion, d.storeVersion, d.preparedVersion].join(',')"), "\(CEFExtensionShim.version),1.0,1.0.2")
        XCTAssertEqual(string(js, "bodies()[1].detail.delivered.map(function (d) { return d.event + ':' + (d.reason || '') + ':' + (d.previousVersion || ''); }).join(',')"), "onInstalled:update:0.9,onStartup::")
        js.evaluateScript("startNow();")
        XCTAssertEqual(string(js, "fetchCalls.length"), "2", "nothing is posted or delivered twice")
    }

    func testInstallAloneAndStartupAloneAndNothing() throws {
        let install = try worker(extraSetup: "fetchReply = '{\"onInstalled\":{\"reason\":\"install\"}}';")
        install.evaluateScript("chrome.runtime.onInstalled.addListener(function (d) { log.push(JSON.stringify(d)); }); chrome.runtime.onStartup.addListener(function () { log.push('startup'); });")
        install.evaluateScript("startNow();")
        XCTAssertEqual(log(install), #"{"reason":"install"}"#)
        XCTAssertEqual(string(install, "bodies()[1].detail.delivered.length"), "1")
        let nothing = try worker(extraSetup: "fetchReply = '{}';")
        nothing.evaluateScript("chrome.runtime.onInstalled.addListener(function () { log.push('x'); });")
        nothing.evaluateScript("startNow();")
        XCTAssertEqual(log(nothing), "")
        XCTAssertEqual(string(nothing, "fetchCalls.length"), "1", "nothing delivered, nothing reported")
        let none = try worker(extraSetup: "fetchReply = '{\"onInstalled\":{\"reason\":\"install\"},\"onStartup\":true}';")
        none.evaluateScript("startNow();")
        XCTAssertEqual(string(none, "bodies()[1].kind + ':' + bodies()[1].detail.delivered.length"), "lifecycle.delivered:2", "an event with no listeners still counts as delivered")
    }

    func testNoAnswerAnErrorOrAnInvalidAnswerDeliversNothingAndThrowsNothing() throws {
        let replies = [
            ("reject", ""), ("error", "fetchReply = '{\"onInstalled\":{\"reason\":\"install\"}}';"), ("reply", "fetchReply = 'not json';"),
            ("reply", "fetchReply = '{\"onInstalled\":{\"reason\":\"update\"}}';"), ("reply", "fetchReply = '{\"onInstalled\":{\"reason\":\"chrome_update\"},\"onStartup\":\"yes\"}';"),
        ]
        for (mode, setup) in replies {
            let js = try worker(extraSetup: "fetchMode = '\(mode)'; \(setup)")
            js.evaluateScript("chrome.runtime.onInstalled.addListener(function () { log.push('installed'); }); chrome.runtime.onStartup.addListener(function () { log.push('startup'); });")
            js.evaluateScript("startNow();")
            XCTAssertEqual(log(js), "", "\(mode) \(setup)")
            XCTAssertEqual(string(js, "fetchCalls.length"), "1", "\(mode) \(setup)")
        }
        let hang = try worker(extraSetup: "fetchMode = 'hang';")
        hang.evaluateScript("chrome.runtime.onInstalled.addListener(function () { log.push('installed'); });")
        hang.evaluateScript("startNow(); timers.forEach(function (f) { f(); });")
        XCTAssertEqual(log(hang), "")
        let noFetch = try context(withFetch: false, extraSetup: """
        function addEventListener() {}
        chrome.runtime.onInstalled = { addListener: function () {} };
        chrome.runtime.onStartup = { addListener: function () {} };
        chrome.runtime.onInstalled.addListener = function () {};
        """)
        noFetch.evaluateScript("timers.filter(function (f) { return f.ms === 0; }).forEach(function (f) { f(); });")
        XCTAssertEqual(log(noFetch), "")
    }

    func testActivationIsReportedWithoutWaiting() throws {
        let js = try worker(extraSetup: "fetchMode = 'hang';")
        js.evaluateScript("swListeners.activate({}); log.push('returned');")
        XCTAssertEqual(log(js), "returned")
        XCTAssertEqual(string(js, "bodies()[0].kind"), "worker.activated")
        XCTAssertEqual(string(js, "JSON.stringify(bodies()[0].detail)"), #"{"shimVersion":\#(CEFExtensionShim.version),"storeVersion":"1.0","preparedVersion":"1.0.2"}"#)
        let bare = try worker()
        bare.evaluateScript("startNow();")
        bare.evaluateScript("swListeners.activate({});")
        XCTAssertEqual(string(bare, "bodies().map(function (b) { return b.kind; }).join(',')"), "worker.started,worker.activated")
    }

    func testPagesKeepChromiumsLifecycleEvents() throws {
        let js = try context(extraSetup: """
        var real = { addListener: function () { log.push('real'); } };
        chrome.runtime.onInstalled = real;
        """)
        XCTAssertEqual(string(js, "chrome.runtime.onInstalled === real"), "true")
        XCTAssertEqual(log(js), "")
    }

    func testPermissionsRequestGrantsWhatIsHeldAndNothingElse() throws {
        let js = try context()
        js.evaluateScript("""
        chrome.permissions.request({ permissions: ['storage'] }).then(function (v) { log.push('held:' + v); });
        chrome.permissions.request({ permissions: ['history'] }).then(function (v) { log.push('new:' + v); });
        chrome.permissions.request({ origins: ['https://a.example/*'] }, function (v) { log.push('cb:' + v + ':' + arguments.length); });
        chrome.permissions.request(undefined).then(function (v) { log.push('odd:' + v); });
        """)
        XCTAssertEqual(log(js), "contains:{\"permissions\":[\"storage\"]}|contains:{\"permissions\":[\"history\"]}|contains:{\"origins\":[\"https://a.example/*\"]}|contains:undefined|held:true|new:false|cb:false:1|odd:false")
        XCTAssertFalse(log(js)?.contains("NATIVE") ?? true)
    }

    func testTheInfoGlobalIsGoneOnceTheShimHasReadIt() throws {
        let js = try context(extraSetup: "globalThis[Symbol.for('brw.cefInfo')] = { token: 'secret', storeVersion: '1.0', preparedVersion: '1.0.4' };")
        XCTAssertEqual(string(js, "String(globalThis[Symbol.for('brw.cefInfo')])"), "undefined")
        js.evaluateScript("chrome.runtime.reload();")
        XCTAssertEqual(string(js, "JSON.parse(fetchCalls[0].body).token"), "secret", "the shim kept what it read")
    }

    func testTabsUpdateNeverNavigatesToAFileUrlOrAnOtherwiseUnlistedScheme() throws {
        let js = try context()
        js.evaluateScript("""
        var urls = ['file:///Users/me/', 'FILE:///etc/hosts', '  file:///a', 'fi\\nle:///a', '\\tFile://host/a', 'data:text/html,x', 'javascript:alert(1)',
                    'chrome-extension://other/p.html', 'blob:https://a.example/x', 'ftp://a.example/'];
        urls.forEach(function (u) { chrome.tabs.update(5, { url: u }).then(function () { log.push('ok:' + u); }, function (e) { log.push('no:' + e.message); }); });
        chrome.tabs.update(5, { url: 'file:///x' }, function (t) { log.push('cb:' + t + ':' + chrome.runtime.lastError.message); });
        chrome.tabs.update({ url: 'file:///x' }).catch(function (e) { log.push('noid:' + e.message); });
        """)
        let entries = (log(js) ?? "").components(separatedBy: "|")
        XCTAssertEqual(entries.filter { $0.hasPrefix("ok:") }, [])
        XCTAssertEqual(entries.filter { $0 == "no:Extensions are not allowed to navigate to file URLs." }.count, 5)
        XCTAssertTrue(entries.contains("noid:Extensions are not allowed to navigate to file URLs."), "also with the tab id left out")
        XCTAssertEqual(entries.filter { $0 == "no:Cannot navigate to this URL." }.count, 5)
        XCTAssertTrue(entries.contains("cb:undefined:Extensions are not allowed to navigate to file URLs."))
        XCTAssertEqual(string(js, "updateCalls.length"), "0", "nothing reached Chromium")
        js.evaluateScript("""
        log.length = 0;
        ['https://a.example/x', 'http://a.example/', 'HTTPS://A.example/', 'page.html', '/popup.html', '../x.html', '//host/x', 'about:blank',
         'chrome-extension://abc/page.html', 'CHROME-EXTENSION://ABC/p.html?x=1', 'x.html#file:///a', 'a/file:///b', undefined].forEach(function (u) {
          chrome.tabs.update(7, { url: u, muted: true });
        });
        """)
        XCTAssertEqual(string(js, "updateCalls.length"), "13", "allowed and relative URLs, and calls with no url, pass through")
        XCTAssertEqual(string(js, "updateCalls.map(function (c) { return c[1].url; }).slice(0, 3).join(',')"), "https://a.example/x,http://a.example/,HTTPS://A.example/")
    }
}
