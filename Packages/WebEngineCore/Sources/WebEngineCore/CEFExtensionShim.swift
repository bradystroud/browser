import Foundation

/// The script that keeps a Chrome extension from reaching the parts of
/// Chromium's tab and window machinery that an Alloy-style CEF tab does not
/// have, and the names the rest of the CEF extension layer shares with it.
///
/// An Alloy browser has no Chrome `Browser` behind it. `windows.create`,
/// `runtime.openOptionsPage` and an interactive `identity.launchWebAuthFlow`
/// make one anyway, as a window the app does not own that takes the keyboard
/// and crashes the next quit. `tabs.update` with `autoDiscardable` or
/// `openerTabId`, and `tabs.discard` with a tab id, dereference state an
/// Alloy tab lacks and take the browser process down. The script replaces
/// those entry points before the extension's own code runs, in the worker
/// and in every extension page, and tells the app what the extension wanted
/// to open (`CEFExtensionShim.bridgeOrigin`).
///
/// It is containment for ordinary extension code, not a security boundary: a
/// document of the extension's origin that is not an HTML page (an SVG, an
/// XHTML file, a `blob:` URL) is only reached by the patches the script
/// applies when a page touches such a frame.
public enum CEFExtensionShim {
    /// Bumps when the script or the way it is loaded changes. It is part of
    /// the file names the preparer writes: Chromium keeps a profile's old
    /// service-worker script when a file keeps its name, so a new script
    /// needs a new path in the manifest.
    public static let version = 5

    /// The reserved origin the script posts to. `.invalid` never resolves, so
    /// a request that the browser does not answer itself goes nowhere.
    public static let bridgeOrigin = "https://extension-bridge.browser.invalid"

    /// The manifest's host permission for the channel. Without it the script
    /// cannot read the reply.
    public static let bridgeHostPermission = bridgeOrigin + "/*"

    /// How long the script waits for the app's reply before it carries on
    /// without one.
    public static let replyTimeoutMilliseconds = 5000

    /// Written at the extension's root, so a root-relative URL names it from
    /// a worker and from a page at any depth. No file the preparer writes has
    /// a name that starts with an underscore: Chromium reserves those, and
    /// refuses a folder that holds one when it reloads it.
    public static let fileName = "brw-cef-shim.v\(version).js"

    /// Chromium keeps a profile's service-worker registration and its script
    /// across a folder change that leaves the worker's path alone. Whenever
    /// the prepared content changes, for a new shim or a new store version,
    /// the worker needs a new path and the manifest a new `version`, together:
    /// the path alone strands the old registration on a file that is gone, the
    /// version alone keeps the old script. Both derive from the two versions
    /// here (`workerFileName`, `preparedVersion`) and nowhere else.
    public static func workerFileName(storeVersion: String, shimVersion: Int = version, revision: Int? = nil) -> String {
        let safe = String(storeVersion.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (scalar.properties.isAlphabetic || (48...57).contains(scalar.value) || scalar == ".") ? Character(scalar) : "_"
        })
        return "brw-background.v\(shimVersion)-\(safe)\(revision.map { "-r\($0)" } ?? "").js"
    }

    /// Where the worker wrapper goes: beside the original worker, so every
    /// relative URL the worker resolves against its own script URL
    /// (`importScripts`, `fetch`, `new URL(x, self.location)`) keeps its base.
    public static func workerPath(original: String, storeVersion: String, shimVersion: Int = version, revision: Int? = nil) -> String {
        let name = workerFileName(storeVersion: storeVersion, shimVersion: shimVersion, revision: revision)
        guard let slash = original.lastIndex(of: "/") else { return name }
        return String(original[...slash]) + name
    }

    /// The manifest `version` for a store version, a shim version and an
    /// optional content revision (an unpacked folder edited without a version
    /// change). The shim version, then the revision plus one (so that revision
    /// 0 differs from none: Chrome reads `1.0.1` and `1.0.1.0` as equal), are
    /// each added as one more part while the store's has fewer than four, and
    /// added to the fourth after that. Parts are 0 to 65535, with no leading
    /// zeros (Chrome's rule). Nil when the store version is not one, or the
    /// result does not fit.
    public static func preparedVersion(storeVersion: String, shimVersion: Int, revision: Int? = nil) -> String? {
        let parts = storeVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), shimVersion >= 1 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), part == "0" || !part.hasPrefix("0"),
                  let number = Int(part), number <= 65535 else { return nil }
            numbers.append(number)
        }
        if let revision, revision < 0 { return nil }
        for extra in [shimVersion] + (revision.map { [$0 + 1] } ?? []) {
            if numbers.count < 4 { numbers.append(extra) } else { numbers[3] += extra }
        }
        guard numbers.allSatisfy({ $0 <= 65535 }) else { return nil }
        return numbers.map(String.init).joined(separator: ".")
    }

    /// The largest content revision that still gives a valid Chrome `version`
    /// for `storeVersion`, or nil when none does. A caller that counts revisions
    /// stops here, since the preparer refuses anything above it.
    public static func maximumRevision(storeVersion: String, shimVersion: Int = version) -> Int? {
        guard preparedVersion(storeVersion: storeVersion, shimVersion: shimVersion, revision: 0) != nil else { return nil }
        var low = 0, high = 65535
        while low < high {
            let mid = (low + high + 1) / 2
            if preparedVersion(storeVersion: storeVersion, shimVersion: shimVersion, revision: mid) != nil { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The URL of a request kind. The shim posts `tabs.create`, `windows.create`,
    /// `runtime.openOptionsPage`, `runtime.reload`, `action.openPopup`,
    /// `identity.launchWebAuthFlow`, `management.uninstallSelf`,
    /// `clients.openWindow`, `worker.started`, `worker.activated` and
    /// `lifecycle.delivered`.
    public static func bridgeURL(kind: String) -> String {
        "\(bridgeOrigin)/v1/\(kind)"
    }

    /// Every replacement carries this symbol, which is how a test (or a
    /// caller that must be sure) tells the replacement from Chromium's own
    /// function.
    public static let markerSymbolKey = "brw.cefShim"

    /// What the shim needs to know about the extension it is part of, written
    /// as the first line of the shim file so no second read happens at run
    /// time. `addedVersionName` says the preparer wrote `version_name` itself.
    /// `token` is random per prepared copy and goes with every request to the
    /// app, which refuses a request without it: a web page cannot learn it.
    public static let infoSymbolKey = "brw.cefInfo"

    public static func fileContents(storeVersion: String, preparedVersion: String, addedVersionName: Bool, token: String) -> String {
        let info: [String: Any] = ["storeVersion": storeVersion, "preparedVersion": preparedVersion, "addedVersionName": addedVersionName, "token": token]
        let data = (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return "globalThis[Symbol.for('\(infoSymbolKey)')] = \(String(decoding: data, as: UTF8.self));\n" + source
    }

    /// Runs as a classic script, a module, or a worker script alike.
    public static let source = #"""
    // Written into this extension by the browser. Chromium's Chrome-style tab and
    // window machinery is missing behind an app tab: this replaces the entry
    // points that would create a window the app does not own or crash the browser
    // process, before the extension's own code runs, and passes what the
    // extension wanted to the app.
    (() => {
      'use strict';
      const MARK = Symbol.for('brw.cefShim');
      const VERSION = \#(version);
      const BRIDGE = '\#(bridgeOrigin)/v1/';
      const REPLY_TIMEOUT = \#(replyTimeoutMilliseconds);
      const MAX_RECORDED = 100;
      const g = globalThis;
      if (g[MARK]) return;

      const INFO = g[Symbol.for('brw.cefInfo')] || {};
      const info = {
        shimVersion: VERSION,
        storeVersion: typeof INFO.storeVersion === 'string' ? INFO.storeVersion : null,
        preparedVersion: typeof INFO.preparedVersion === 'string' ? INFO.preparedVersion : null
      };
      // Read once and removed: nothing later in this realm finds it by name.
      try { delete g[Symbol.for('brw.cefInfo')]; } catch (_) {}
      const TOKEN = typeof INFO.token === 'string' ? INFO.token : undefined;
      const nativeFetch = typeof g.fetch === 'function' ? g.fetch.bind(g) : null;
      const blocked = [];

      function mark(fn) {
        Object.defineProperty(fn, MARK, { value: true });
        return fn;
      }

      // Only methods are replaced, on the cached binding object. The namespace
      // properties (chrome.tabs, browser.tabs) are lazy and Chromium installs
      // them again when permissions change, handing back that same object, so
      // the replacements survive and the namespaces are left alone.
      function lock(obj, name, value) {
        try {
          Object.defineProperty(obj, name, { value, writable: false, configurable: false, enumerable: true });
          return obj[name] === value;
        } catch (_) {
          return false;
        }
      }

      function plain(value) {
        const kind = typeof value;
        if (kind === 'string') return String(value);
        if (kind === 'number' || kind === 'boolean') return value;
        return undefined;
      }

      // Reads each key exactly once, so a getter or a Proxy cannot show one
      // value to this code and another to whoever reads the result next.
      function pick(source, keys) {
        const out = {};
        if (source === null || typeof source !== 'object') return out;
        for (const key of keys) {
          let value;
          try { value = source[key]; } catch (_) { continue; }
          value = plain(value);
          if (value !== undefined) out[key] = value;
        }
        return out;
      }

      function absoluteURL(runtime, url) {
        if (typeof url !== 'string') return undefined;
        try {
          return new URL(url, runtime.getURL('/')).href;
        } catch (_) {
          return url;
        }
      }

      // Posts what the extension wanted to the app and resolves with
      // { ok, body }: ok when the app answered 2xx, body the JSON object it
      // answered or null. It never rejects and never throws: a missing
      // channel, a refused request, a reply that is not JSON, or a reply that
      // does not come in time all give { ok: false, body: null }.
      function post(kind, detail) {
        if (blocked.length < MAX_RECORDED) blocked.push({ kind, detail, at: Date.now() });
        return new Promise((resolve) => {
          let done = false;
          let timer;
          let controller = null;
          const finish = (value) => {
            if (done) return;
            done = true;
            try { if (timer !== undefined) clearTimeout(timer); } catch (_) {}
            resolve(value);
          };
          const failed = { ok: false, body: null };
          try {
            if (!nativeFetch) return finish(failed);
            controller = typeof g.AbortController === 'function' ? new g.AbortController() : null;
            timer = setTimeout(() => {
              try { if (controller) controller.abort(); } catch (_) {}
              finish(failed);
            }, REPLY_TIMEOUT);
            // text/plain keeps this a simple request, so no preflight can fail.
            nativeFetch(BRIDGE + kind, {
              method: 'POST',
              headers: { 'Content-Type': 'text/plain;charset=UTF-8' },
              body: JSON.stringify({ kind, version: VERSION, token: TOKEN, detail }),
              credentials: 'omit',
              cache: 'no-store',
              signal: controller ? controller.signal : undefined
            }).then((response) => response.text().then((text) => {
                let parsed = null;
                try { parsed = text ? JSON.parse(text) : null; } catch (_) {}
                finish({ ok: response.ok !== false, body: parsed !== null && typeof parsed === 'object' ? parsed : null });
              }))
              .catch(() => finish(failed));
          } catch (_) {
            finish(failed);
          }
        });
      }

      // The JSON object the app answered, or null.
      function forward(kind, detail) {
        return post(kind, detail).then((result) => result.body);
      }

      // A callback runs after the call returns, with chrome.runtime.lastError
      // set while it runs when the call failed, as in Chrome. If the
      // property cannot be set the callback still runs.
      function callBackWithError(runtime, callback, message) {
        let restore = null;
        try {
          if (runtime) {
            const previous = Object.getOwnPropertyDescriptor(runtime, 'lastError');
            if (!previous || previous.configurable) {
              Object.defineProperty(runtime, 'lastError', {
                configurable: true, enumerable: true, get() { return { message }; }
              });
              restore = () => {
                if (previous) Object.defineProperty(runtime, 'lastError', previous);
                else delete runtime.lastError;
              };
            }
          }
        } catch (_) { restore = null; }
        try {
          callback();
        } finally {
          try { if (restore) restore(); } catch (_) {}
        }
      }

      // Chrome's promise-or-callback convention: a trailing function means the
      // callback form, which returns undefined; otherwise a promise.
      function trailingCallback(args) {
        const last = args[args.length - 1];
        return typeof last === 'function' ? last : undefined;
      }

      // Settles a call from the app's answer: the promise form follows the
      // promise, the callback form calls back (with lastError set on failure).
      function succeed(runtime, callback, promise) {
        if (callback) {
          promise.then(
            (value) => (value === undefined ? callback() : callback(value)),
            (error) => callBackWithError(runtime, callback, error && error.message));
          return undefined;
        }
        return promise;
      }

      // The app answered 2xx, or the call fails with Chrome's message.
      function answered(message) {
        return (result) => {
          if (!result.ok) throw new Error(message);
          return result.body;
        };
      }

      function fail(runtime, callback, message) {
        if (callback) {
          Promise.resolve().then(() => callBackWithError(runtime, callback, message));
          return undefined;
        }
        return Promise.reject(new Error(message));
      }

      const TAB_REPLY_KEYS = ['id', 'index', 'windowId', 'url', 'pendingUrl', 'title', 'active',
        'highlighted', 'pinned', 'status', 'incognito'];
      const WINDOW_REPLY_KEYS = ['id', 'focused', 'top', 'left', 'width', 'height', 'type', 'state',
        'incognito', 'alwaysOnTop'];

      function fakeTab(url, reply) {
        return Object.assign({
          id: -1, index: -1, windowId: -1, highlighted: true, active: true, pinned: false,
          audible: false, discarded: false, autoDiscardable: true, incognito: false, groupId: -1,
          selected: true, frozen: false, pendingUrl: url, status: 'loading'
        }, pick(reply, TAB_REPLY_KEYS));
      }

      function fakeWindow(urls, reply) {
        return Object.assign({
          id: -1, focused: true, top: 0, left: 0, width: 0, height: 0, incognito: false,
          type: 'normal', state: 'normal', alwaysOnTop: false, tabs: urls.map((url) => fakeTab(url))
        }, pick(reply, WINDOW_REPLY_KEYS));
      }

      // The keys tabs.update may pass on. autoDiscardable and openerTabId are
      // left out on purpose: both reach state an app tab does not have.
      const UPDATE_KEYS = ['url', 'active', 'highlighted', 'selected', 'pinned', 'muted'];
      function sanitizedUpdate(properties) {
        if (properties === null || typeof properties !== 'object') return properties;
        const out = {};
        for (const key of UPDATE_KEYS) {
          let value;
          try { value = properties[key]; } catch (_) { continue; }
          if (value !== undefined) out[key] = value;
        }
        return out;
      }

      // Why tabs.update may not navigate to `url`, or null. Only http, https,
      // about:blank and the extension's own pages are allowed; a relative URL
      // resolves to the extension's own pages. Browsers drop tabs and newlines
      // and surrounding control characters before they read the scheme.
      function refusedNavigation(runtime, url) {
        if (typeof url !== 'string') return null;
        const cleaned = url.replace(/[\t\n\r]/g, '').replace(/^[\u0000-\u0020]+|[\u0000-\u0020]+$/g, '');
        const match = /^([a-z][a-z0-9+.-]*):/i.exec(cleaned);
        if (!match) return null;
        const scheme = match[1].toLowerCase();
        if (scheme === 'http' || scheme === 'https') return null;
        if (scheme === 'about' && /^about:blank([?#]|$)/i.test(cleaned)) return null;
        if (scheme === 'chrome-extension') {
          let own = '';
          try { own = String(runtime.getURL('/')).toLowerCase(); } catch (_) {}
          if (own && cleaned.toLowerCase().indexOf(own) === 0) return null;
        }
        return scheme === 'file' ? 'Extensions are not allowed to navigate to file URLs.' : 'Cannot navigate to this URL.';
      }

      const status = {};

      // A command-line extension is told it was installed at every launch, never
      // that it started, and not that it was updated. The shim owns both events:
      // it keeps one listener of its own with Chromium (so the worker still wakes
      // at launch), ignores what Chromium sends, and dispatches to the
      // extension's listeners what the app says is due.
      function makeEvent(label) {
        const listeners = [];
        class RuntimeEvent {
          addListener(listener) {
            if (typeof listener !== 'function') {
              throw new TypeError('Error in invocation of runtime.' + label + '.addListener(function callback): No matching signature.');
            }
            if (listeners.indexOf(listener) < 0) listeners.push(listener);
          }
          removeListener(listener) {
            const index = listeners.indexOf(listener);
            if (index >= 0) listeners.splice(index, 1);
          }
          hasListener(listener) { return listeners.indexOf(listener) >= 0; }
          hasListeners() { return listeners.length > 0; }
        }
        const api = new RuntimeEvent();
        Object.defineProperty(api, MARK, { value: true });
        const dispatch = (...args) => {
          listeners.slice().forEach((listener) => {
            try { listener(...args); } catch (e) { setTimeout(() => { throw e; }); }
          });
        };
        return { api, dispatch };
      }

      const IS_WORKER = typeof document === 'undefined' && typeof g.addEventListener === 'function';
      function setupLifecycle() {
        const installed = makeEvent('onInstalled');
        const startup = makeEvent('onStartup');
        const registered = new Set();
        const delivered = new Set();
        const noop = function () {};
        let started = false;

        g.addEventListener('activate', () => { post('worker.activated', Object.assign({}, info)); });

        // After the extension's top-level code, which runs right after this file.
        setTimeout(() => {
          if (started) return;
          started = true;
          post('worker.started', Object.assign({}, info)).then((result) => {
            const body = result.ok ? result.body : null;
            if (!body) return;
            const done = [];
            const offered = body.onInstalled;
            if (offered !== null && typeof offered === 'object' && !delivered.has('onInstalled')) {
              const reason = offered.reason;
              const previous = plain(offered.previousVersion);
              if (reason === 'install' || (reason === 'update' && typeof previous === 'string')) {
                delivered.add('onInstalled');
                const details = reason === 'update' ? { reason, previousVersion: previous } : { reason };
                installed.dispatch(details);
                done.push(Object.assign({ event: 'onInstalled' }, details));
              }
            }
            if (body.onStartup === true && !delivered.has('onStartup')) {
              delivered.add('onStartup');
              startup.dispatch();
              done.push({ event: 'onStartup' });
            }
            if (done.length) post('lifecycle.delivered', Object.assign({}, info, { delivered: done }));
          }).catch(() => {});
        }, 0);

        return {
          own(runtime, label) {
            for (const [name, event] of [['onInstalled', installed], ['onStartup', startup]]) {
              let real;
              try { real = runtime[name]; } catch (_) {}
              if (real && !real[MARK] && typeof real.addListener === 'function' && !registered.has(real)) {
                registered.add(real);
                try { real.addListener(noop); } catch (_) {}
              }
              status[label + '.runtime.' + name] = lock(runtime, name, event.api);
            }
          }
        };
      }
      const lifecycle = IS_WORKER ? setupLifecycle() : null;

      function patchNamespace(root, label) {
        if (!root || typeof root !== 'object') return;
        const tabs = root.tabs;
        const windows = root.windows;
        const runtime = root.runtime;
        const identity = root.identity;

        if (tabs) {
          if (typeof tabs.create === 'function') {
            status[label + '.tabs.create'] = lock(tabs, 'create', mark(function create(createProperties, callback) {
              if (typeof createProperties === 'function') { callback = createProperties; createProperties = undefined; }
              callback = typeof callback === 'function' ? callback : undefined;
              const url = absoluteURL(runtime, createProperties && createProperties.url);
              const detail = Object.assign(pick(createProperties, ['active', 'pinned']), url === undefined ? {} : { url });
              return succeed(runtime, callback, post('tabs.create', detail).then(answered('No current window'))
                .then((reply) => fakeTab(url, reply && reply.tab)));
            }));
          }
          if (typeof tabs.update === 'function') {
            const originalUpdate = tabs.update;
            status[label + '.tabs.update'] = lock(tabs, 'update', mark(function update(...args) {
              const out = [];
              let at = 0;
              // A tab id may be left out as undefined or null when properties follow.
              if (typeof args[0] === 'number'
                  || ((args[0] === undefined || args[0] === null) && args.length > 1 && typeof args[1] !== 'function')) {
                out.push(args[0]); at = 1;
              }
              const properties = sanitizedUpdate(args[at]);
              out.push(properties);
              const callback = typeof args[at + 1] === 'function' ? args[at + 1] : undefined;
              if (callback) out.push(callback);
              // Chromium lets a command-line extension navigate a tab to a file: URL.
              const refusal = properties !== null && typeof properties === 'object' ? refusedNavigation(runtime, properties.url) : null;
              if (refusal) return fail(runtime, callback, refusal);
              return originalUpdate.apply(tabs, out);
            }));
          }
          if (typeof tabs.discard === 'function') {
            status[label + '.tabs.discard'] = lock(tabs, 'discard', mark(function discard(tabId, callback) {
              if (typeof tabId === 'function') { callback = tabId; tabId = undefined; }
              callback = typeof callback === 'function' ? callback : undefined;
              return fail(runtime, callback, tabId === undefined
                ? 'Cannot find a tab to discard.' : 'Cannot discard tab with id: ' + plain(tabId) + '.');
            }));
          }
        }

        if (windows && typeof windows.create === 'function') {
          status[label + '.windows.create'] = lock(windows, 'create', mark(function create(createData, callback) {
            if (typeof createData === 'function') { callback = createData; createData = undefined; }
            callback = typeof callback === 'function' ? callback : undefined;
            let url;
            try { url = createData && createData.url; } catch (_) { url = undefined; }
            const urls = (Array.isArray(url) ? url : [url]).map((one) => absoluteURL(runtime, one));
            const detail = Object.assign(pick(createData, ['type', 'width', 'height', 'focused', 'incognito']),
              { url: urls.filter((one) => one !== undefined) });
            return succeed(runtime, callback, post('windows.create', detail).then(answered('Could not create window.'))
              .then((reply) => fakeWindow(urls, reply && reply.window)));
          }));
        }

        if (identity && typeof identity.launchWebAuthFlow === 'function') {
          // Only an interactive flow opens a popup Browser window; the silent
          // form has nothing to show and goes to Chromium.
          const originalLaunch = identity.launchWebAuthFlow;
          status[label + '.identity.launchWebAuthFlow'] = lock(identity, 'launchWebAuthFlow', mark(function launchWebAuthFlow(details, callback) {
            let interactive = false;
            try { interactive = !!(details && details.interactive); } catch (_) {}
            if (!interactive) return originalLaunch.apply(identity, arguments);
            callback = typeof callback === 'function' ? callback : undefined;
            post('identity.launchWebAuthFlow', { url: absoluteURL(runtime, details && details.url) });
            return fail(runtime, callback, 'Authorization page could not be loaded.');
          }));
        }

        const management = root.management;
        if (management && typeof management.uninstallSelf === 'function') {
          // It needs no permission, and an extension that removes itself drops
          // out of the profile until the app relaunches.
          status[label + '.management.uninstallSelf'] = lock(management, 'uninstallSelf', mark(function uninstallSelf(options, callback) {
            if (typeof options === 'function') { callback = options; options = undefined; }
            callback = typeof callback === 'function' ? callback : undefined;
            post('management.uninstallSelf', pick(options, ['showConfirmDialog']));
            return fail(runtime, callback, 'User cancelled uninstall');
          }));
        }

        if (runtime && typeof runtime.getManifest === 'function' && info.storeVersion !== null) {
          // The extension sees the version the store published.
          const getManifest = runtime.getManifest;
          status[label + '.runtime.getManifest'] = lock(runtime, 'getManifest', mark(function getManifest_() {
            const manifest = getManifest.apply(runtime, arguments);
            if (manifest !== null && typeof manifest === 'object') {
              manifest.version = info.storeVersion;
              if (INFO.addedVersionName === true) delete manifest.version_name;
            }
            return manifest;
          }));
        }
        if (runtime && lifecycle) lifecycle.own(runtime, label);

        const action = root.action;
        if (action && typeof action.openPopup === 'function') {
          // There is no Chrome window to open a popup in; the app hosts it.
          // Chrome's own failure is what an extension's fallback expects.
          status[label + '.action.openPopup'] = lock(action, 'openPopup', mark(function openPopup(options, callback) {
            if (typeof options === 'function') { callback = options; options = undefined; }
            callback = typeof callback === 'function' ? callback : undefined;
            const outcome = post('action.openPopup', pick(options, ['windowId'])).then((result) => {
              if (!result.ok) throw new Error('Failed to open popup.');
            });
            return succeed(runtime, callback, outcome);
          }));
        }

        const permissionsApi = root.permissions;
        if (permissionsApi && typeof permissionsApi.request === 'function' && typeof permissionsApi.contains === 'function') {
          // The user agreed to the manifest's permissions for Chromium tabs, not to
          // anything asked for later. What the extension already holds is
          // granted, and nothing else is.
          const contains = permissionsApi.contains;
          status[label + '.permissions.request'] = lock(permissionsApi, 'request', mark(function request(wanted, callback) {
            callback = typeof callback === 'function' ? callback : undefined;
            const held = Promise.resolve().then(() => contains.call(permissionsApi, wanted)).then((result) => result === true, () => false);
            return succeed(runtime, callback, held);
          }));
        }

        if (runtime && typeof runtime.reload === 'function') {
          // A command-line extension that reloads itself drops out of the
          // profile until the app relaunches, so the app is asked instead.
          status[label + '.runtime.reload'] = lock(runtime, 'reload', mark(function reload() {
            forward('runtime.reload', {});
            return undefined;
          }));
        }

        if (runtime && typeof runtime.openOptionsPage === 'function') {
          status[label + '.runtime.openOptionsPage'] = lock(runtime, 'openOptionsPage', mark(function openOptionsPage(callback) {
            callback = typeof callback === 'function' ? callback : undefined;
            let page;
            try {
              const manifest = runtime.getManifest();
              page = (manifest.options_ui && manifest.options_ui.page) || manifest.options_page;
              page = page && runtime.getURL(page);
            } catch (_) {}
            if (!page) return fail(runtime, callback, 'Could not create an options page.');
            return succeed(runtime, callback, post('runtime.openOptionsPage', { url: page })
              .then(answered('Could not create an options page.')).then(() => undefined));
          }));
        }
      }

      patchNamespace(g.chrome, 'chrome');
      if (g.browser && g.browser !== g.chrome) patchNamespace(g.browser, 'browser');

      if (g.Clients && g.Clients.prototype && typeof g.Clients.prototype.openWindow === 'function') {
        status['Clients.openWindow'] = lock(g.Clients.prototype, 'openWindow', mark(function openWindow(url) {
          const target = typeof url === 'string' ? String(url) : undefined;
          return forward('clients.openWindow', { url: target }).then(() => null);
        }));
      }

      Object.defineProperty(g, MARK, { value: Object.freeze({ version: VERSION, status, blocked }) });

      // Beyond here: pages only. Any document of the extension's origin gets
      // the full API: an SVG, XHTML or text file, a blob: URL, a page the
      // preparer could not put this file into. Chromium does not apply the
      // extension's own CSP to its own resources, so this realm patches every
      // other window it can reach before handing it back, and every frame on
      // each load.
      if (typeof document === 'undefined' || typeof g.HTMLIFrameElement !== 'function') return;
      function patchWindow(w) {
        try {
          if (w && w !== g && !w[MARK] && w.chrome) {
            patchNamespace(w.chrome, 'chrome');
            if (w.browser && w.browser !== w.chrome) patchNamespace(w.browser, 'browser');
            Object.defineProperty(w, MARK, { value: Object.freeze({ version: VERSION, status: {}, blocked, patchedFrom: 'parent' }) });
          }
        } catch (_) { /* cross-origin: no API there */ }
        return w;
      }
      function wrapGetter(proto, name, toWindow) {
        const descriptor = proto && Object.getOwnPropertyDescriptor(proto, name);
        if (!descriptor || typeof descriptor.get !== 'function') return;
        const get = descriptor.get;
        Object.defineProperty(proto, name, {
          configurable: false, enumerable: descriptor.enumerable,
          get: function () { const value = get.call(this); if (value) patchWindow(toWindow(value)); return value; }
        });
      }
      const asWindow = (value) => value;
      const documentWindow = (doc) => doc && doc.defaultView;
      for (const C of [g.HTMLIFrameElement, g.HTMLFrameElement, g.HTMLObjectElement]) {
        if (!C) continue;
        wrapGetter(C.prototype, 'contentWindow', asWindow);
        wrapGetter(C.prototype, 'contentDocument', documentWindow);
      }
      for (const C of [g.HTMLObjectElement, g.HTMLEmbedElement, g.HTMLIFrameElement, g.HTMLFrameElement]) {
        const original = C && C.prototype.getSVGDocument;
        if (typeof original === 'function') {
          lock(C.prototype, 'getSVGDocument', function getSVGDocument() {
            const doc = original.call(this);
            patchWindow(documentWindow(doc));
            return doc;
          });
        }
      }
      wrapGetter(g.MessageEvent && g.MessageEvent.prototype, 'source', asWindow);
      const extension = g.chrome && g.chrome.extension;
      if (extension && typeof extension.getViews === 'function') {
        const getViews = extension.getViews;
        lock(extension, 'getViews', function getViewsPatched(filter) { return getViews.call(extension, filter).map(patchWindow); });
      }
      const sweep = () => { for (let i = 0; i < g.frames.length; i++) patchWindow(g.frames[i]); };
      g.addEventListener('load', sweep, true);
      g.addEventListener('DOMContentLoaded', sweep, true);
    })();

    """#
}
