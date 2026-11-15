import Foundation

/// Parts of Chrome's extension API that WebKit's lacks, supplied by a script
/// that runs ahead of the extension's own code in every extension context.
///
/// Code written for Chrome tends to read an API it asked for without
/// checking that it is there. WebKit has no `chrome.privacy` at all and no
/// `webNavigation.onHistoryStateUpdated` or `onTabReplaced`, so one such
/// read at the top level of a background script throws, and the whole
/// worker is gone before it registers a single listener. iCloud Passwords
/// stops at both.
///
/// `WKWebExtension` has no hook for adding an API, so the layer is a file
/// written into the extension's own folder, `shimFile`, and the extension is
/// pointed at it: a classic `service_worker` becomes a small worker that
/// `importScripts` the shim and then the original, a module worker imports
/// both in that order, a `background.scripts` list gets the shim first, and
/// every HTML page with a script gets a `<script>` for the shim before its
/// first one (which covers `background.page`, popups and options pages).
/// Content scripts get nothing: Chrome gives them neither API either.
///
/// It also stops one WebKit fault from taking a web page down: an extension
/// page framed in a web page that calls `action.openPopup()` (see the relay
/// in `shimSource`).
///
/// Only extensions whose manifest asks for a permission in
/// `suppliedPermissions`, or that could frame a page with an action
/// (`framesActionPage`), are touched, and preparing one twice changes
/// nothing the second time.
public enum ChromeExtensionCompatibility {
    public static let shimFile = "__browser_chrome_compat.js"
    public static let workerFile = "__browser_background.js"
    /// The native-messaging host name the browser answers itself for the
    /// settings an extension may hold (see the shim's settingsTransport).
    public static let settingsHost = "dev.stroud.browser.settings"

    /// Permissions whose API WebKit lacks wholly (`privacy`) or in part
    /// (`webNavigation`), and which the shim supplies.
    public static let suppliedPermissions: Set<String> = ["privacy", "webNavigation"]

    public enum PreparationError: Error, Equatable, LocalizedError {
        case unreadableManifest
        /// The extension ships a file under a name the layer writes.
        case nameTaken(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableManifest: return "The extension's manifest.json could not be read."
            case .nameTaken(let name): return "The extension already has a file named \(name)."
            }
        }
    }

    public static func isNeeded(manifest: [String: Any]) -> Bool {
        let permissions = manifest["permissions"] as? [Any] ?? []
        return permissions.contains { ($0 as? String).map(suppliedPermissions.contains) ?? false }
            || framesActionPage(manifest: manifest)
    }

    /// An MV3 extension with a toolbar action and a web-accessible HTML page
    /// can frame its own page inside a web page and call `action.openPopup()`
    /// from there, which WebKit answers by killing the page's process (see
    /// the shim's relay).
    static func framesActionPage(manifest: [String: Any]) -> Bool {
        guard manifest["action"] is [String: Any] else { return false }
        let entries = manifest["web_accessible_resources"] as? [Any] ?? []
        return entries.contains { entry in
            let resources = (entry as? [String: Any])?["resources"] as? [Any] ?? []
            return resources.contains { resource in
                guard let path = (resource as? String)?.lowercased() else { return false }
                return path.hasSuffix(".html") || path.hasSuffix(".htm") || path.hasSuffix("*")
            }
        }
    }

    public static func isNeeded(folder: URL) -> Bool {
        guard let manifest = try? readManifest(in: folder) else { return false }
        return isNeeded(manifest: manifest)
    }

    /// Prepares the unpacked extension in `folder` if it needs the layer.
    /// Returns the paths, relative to `folder`, of every file written; an
    /// extension that does not need it, or is already prepared, gets none.
    @discardableResult
    public static func prepare(folder: URL) throws -> [String] {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        var manifest = try readManifest(in: folder)
        guard isNeeded(manifest: manifest) else { return [] }
        var written: [String] = []

        let shimURL = folder.appendingPathComponent(shimFile)
        if (try? Data(contentsOf: shimURL)) != Data(shimSource.utf8) {
            try Data(shimSource.utf8).write(to: shimURL, options: .atomic)
            written.append(shimFile)
        }

        if var background = manifest["background"] as? [String: Any] {
            var changed = false
            if let worker = background["service_worker"] as? String, worker != workerFile {
                let workerURL = folder.appendingPathComponent(workerFile)
                let isModule = (background["type"] as? String) == "module"
                let wanted = Data(workerSource(wrapping: worker, module: isModule).utf8)
                // A wrapper already here with the manifest still naming the
                // original is this layer's own, left by a preparation that
                // stopped before the manifest was rewritten; anything else
                // under the name is the extension's and is never replaced.
                if let existing = try? Data(contentsOf: workerURL) {
                    guard existing.starts(with: Data(workerHeader.utf8)) else {
                        throw PreparationError.nameTaken(workerFile)
                    }
                    if existing != wanted {
                        try wanted.write(to: workerURL, options: .atomic)
                        written.append(workerFile)
                    }
                } else if FileManager.default.fileExists(atPath: workerURL.path) {
                    throw PreparationError.nameTaken(workerFile)
                } else {
                    try wanted.write(to: workerURL, options: .atomic)
                    written.append(workerFile)
                }
                background["service_worker"] = workerFile
                changed = true
            }
            if let scripts = background["scripts"] as? [Any], (scripts.first as? String) != shimFile {
                background["scripts"] = [shimFile] + scripts
                changed = true
            }
            if changed {
                manifest["background"] = background
                let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                try data.write(to: manifestURL, options: .atomic)
                written.append("manifest.json")
            }
        }

        let base = folder.resolvingSymlinksInPath().path
        for page in htmlPages(in: folder) {
            guard let original = try? Data(contentsOf: page), let updated = insertingShim(into: original) else { continue }
            try updated.write(to: page, options: .atomic)
            written.append(String(page.resolvingSymlinksInPath().path.dropFirst(base.count + 1)))
        }
        return written
    }

    // MARK: - Pieces

    static func readManifest(in folder: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any]
        else { throw PreparationError.unreadableManifest }
        return manifest
    }

    /// Root-relative, so the same tag works in a page at any depth.
    static let scriptTag = "<script src=\"/\(shimFile)\"></script>"

    /// The first line of every wrapper the layer writes, which is how a
    /// wrapper left behind is told from an extension's own file.
    static let workerHeader = "// Written by the browser: runs \(shimFile) ahead of the extension's own worker.\n"

    static func workerSource(wrapping original: String, module: Bool) -> String {
        let path = "/" + original.drop { $0 == "/" }
        let quoted = String(data: try! JSONSerialization.data(withJSONObject: [path], options: [.withoutEscapingSlashes]), encoding: .utf8)!
            .dropFirst().dropLast()
        let header = workerHeader
        if module {
            return header + "import \"/\(shimFile)\";\nimport \(quoted);\n"
        }
        return header + "importScripts(\"/\(shimFile)\", \(quoted));\n"
    }

    static func htmlPages(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return [] }
        var pages: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let ext = url.pathExtension.lowercased()
            if ext == "html" || ext == "htm" { pages.append(url) }
        }
        return pages.sorted { $0.path < $1.path }
    }

    /// `html` with the shim's tag before its first `<script`, outside
    /// comments; nil when it has no script or already has the tag. Works on
    /// bytes, so whatever else the page holds stays byte-for-byte as it was.
    static func insertingShim(into html: Data) -> Data? {
        let bytes = [UInt8](html)
        let tag = Array(scriptTag.utf8)
        if contains(bytes, tag) { return nil }
        let open = Array("<script".utf8)
        let commentOpen = Array("<!--".utf8)
        let commentClose = Array("-->".utf8)
        var i = 0
        while i < bytes.count {
            if matches(bytes, at: i, commentOpen) {
                guard let end = find(bytes, commentClose, from: i + commentOpen.count) else { return nil }
                i = end + commentClose.count
                continue
            }
            if matches(bytes, at: i, open, ignoringCase: true) {
                let next = i + open.count
                let boundary = next < bytes.count ? bytes[next] : 0
                if boundary == UInt8(ascii: ">") || boundary == UInt8(ascii: "/") || boundary == UInt8(ascii: " ")
                    || boundary == UInt8(ascii: "\t") || boundary == UInt8(ascii: "\n") || boundary == UInt8(ascii: "\r") {
                    return Data(bytes[..<i] + tag + bytes[i...])
                }
            }
            i += 1
        }
        return nil
    }

    private static func matches(_ bytes: [UInt8], at index: Int, _ pattern: [UInt8], ignoringCase: Bool = false) -> Bool {
        guard index + pattern.count <= bytes.count else { return false }
        for (offset, expected) in pattern.enumerated() {
            var byte = bytes[index + offset]
            if ignoringCase, byte >= UInt8(ascii: "A"), byte <= UInt8(ascii: "Z") { byte += 32 }
            if byte != expected { return false }
        }
        return true
    }

    private static func find(_ bytes: [UInt8], _ pattern: [UInt8], from start: Int) -> Int? {
        var i = start
        while i + pattern.count <= bytes.count {
            if matches(bytes, at: i, pattern) { return i }
            i += 1
        }
        return nil
    }

    private static func contains(_ bytes: [UInt8], _ pattern: [UInt8]) -> Bool {
        find(bytes, pattern, from: 0) != nil
    }

    /// Runs as a classic script, a module or a worker script alike. It only
    /// ever adds what is missing, so an API WebKit later gains is left as
    /// WebKit made it.
    public static let shimSource = #"""
    // Written into this extension by the browser. WebKit's extension API lacks
    // parts of Chrome's; this supplies them before the extension's own code runs.
    (function () {
      "use strict";
      var api = typeof chrome === "object" && chrome !== null ? chrome
        : typeof browser === "object" && browser !== null ? browser : null;
      if (!api || !api.runtime || typeof api.runtime.getManifest !== "function") return;
      var permissions;
      try { permissions = api.runtime.getManifest().permissions || []; } catch (e) { return; }
      function asked(name) { return permissions.indexOf(name) >= 0; }

      function supply(target, name, value) {
        if (target[name] !== undefined) return target[name];
        try {
          Object.defineProperty(target, name, { value: value, configurable: true, enumerable: true, writable: true });
        } catch (e) {}
        return target[name];
      }

      function makeEvent(onFirstListener) {
        var listeners = [];
        return {
          fire: function () {
            var args = arguments;
            listeners.slice().forEach(function (listener) {
              try { listener.apply(null, args); } catch (e) { setTimeout(function () { throw e; }); }
            });
          },
          event: {
            addListener: function (listener) {
              if (typeof listener !== "function") throw new TypeError("addListener expects a function.");
              if (listeners.indexOf(listener) >= 0) return;
              listeners.push(listener);
              if (listeners.length === 1 && onFirstListener) onFirstListener();
            },
            removeListener: function (listener) {
              var index = listeners.indexOf(listener);
              if (index >= 0) listeners.splice(index, 1);
            },
            hasListener: function (listener) { return listeners.indexOf(listener) >= 0; },
            hasListeners: function () { return listeners.length > 0; }
          }
        };
      }

      // Chrome's callback form calls back later, never inside the call;
      // without a callback it returns a promise.
      function respond(args, result, error) {
        var callback = args.length && typeof args[args.length - 1] === "function" ? args[args.length - 1] : null;
        if (callback) {
          Promise.resolve().then(function () { callback(result); });
          return undefined;
        }
        return error ? Promise.reject(error) : Promise.resolve(result);
      }

      // A ChromeSetting this browser does not let extensions control, which
      // is what levelOfControl says. The value is the browser's own default.
      function uncontrollableSetting(value) {
        return {
          get: function () {
            return respond(arguments, { value: value, levelOfControl: "not_controllable" });
          },
          set: function () {
            return respond(arguments, undefined, new Error("This browser does not let extensions change this setting."));
          },
          clear: function () { return respond(arguments, undefined); },
          onChange: makeEvent().event
        };
      }

      // `promise`'s outcome, in Chrome's callback form when the caller gave
      // a callback (called with no result on failure: runtime.lastError
      // belongs to the engine) and as the promise otherwise.
      function settle(args, promise) {
        var callback = args.length && typeof args[args.length - 1] === "function" ? args[args.length - 1] : null;
        if (!callback) return promise;
        promise.then(function (result) { callback(result); }, function () { callback(); });
        return undefined;
      }

      // How a setting the browser really has reaches the browser. An engine
      // with its own route defines globalThis.__browserSettingsTransport
      // before this script; otherwise the request goes to the browser as a
      // native message on a host name it answers itself, which needs the
      // nativeMessaging permission. Requests are { setting, op: "get" |
      // "set" | "clear", value }; answers { value, levelOfControl } or
      // { error }; changes arrive on a port as { setting, value,
      // levelOfControl }. The caller is whoever the engine says it is, so
      // nothing here names the extension.
      var SETTINGS_HOST = "dev.stroud.browser.settings";
      function settingsTransport() {
        var custom = typeof globalThis === "object" ? globalThis.__browserSettingsTransport : undefined;
        if (custom && typeof custom.request === "function") return custom;
        var runtime = api.runtime;
        if (!asked("nativeMessaging") || typeof runtime.sendNativeMessage !== "function") return null;
        return {
          request: function (message) {
            return new Promise(function (resolve, reject) {
              try {
                runtime.sendNativeMessage(SETTINGS_HOST, message, function (reply) {
                  var failure = runtime.lastError;
                  if (failure || !reply || typeof reply !== "object") {
                    reject(new Error((failure && failure.message) || "The browser did not answer."));
                  } else {
                    resolve(reply);
                  }
                });
              } catch (e) { reject(e); }
            });
          },
          subscribe: function (onEvent) {
            if (typeof runtime.connectNative !== "function") return;
            try { runtime.connectNative(SETTINGS_HOST).onMessage.addListener(onEvent); } catch (e) {}
          }
        };
      }

      // A ChromeSetting the browser keeps per profile and an extension may
      // hold. When the browser cannot be asked, it answers as the
      // not_controllable setting it used to be.
      var framedRefusal = "An extension page shown inside a web page can read this setting but not change it.";
      function controllableSetting(name, fallbackValue, transport) {
        var change = makeEvent(function () {
          if (typeof transport.subscribe !== "function") return;
          transport.subscribe(function (event) {
            if (!event || event.setting !== name || typeof event.value !== "boolean") return;
            change.fire({ value: event.value, levelOfControl: event.levelOfControl });
          });
        });
        function ask(message) {
          return transport.request(message).then(function (reply) {
            if (!reply || reply.error || typeof reply.value !== "boolean") {
              throw new Error((reply && reply.error) || "The browser did not answer.");
            }
            return { value: reply.value, levelOfControl: reply.levelOfControl };
          });
        }
        return {
          get: function () {
            return settle(arguments, ask({ setting: name, op: "get" }).catch(function () {
              return { value: fallbackValue, levelOfControl: "not_controllable" };
            }));
          },
          // A page framed inside a web page runs in that page's own web
          // content process, the less trusted one, so from there the
          // setting may be read but not taken or released. The browser
          // cannot tell where a request came from (WebKit names only the
          // extension), so this is where the line is drawn.
          set: function (details) {
            if (isFramedInWebPage()) return settle(arguments, Promise.reject(new Error(framedRefusal)));
            if (!details || typeof details.value !== "boolean") {
              return settle(arguments, Promise.reject(new Error("The value must be true or false.")));
            }
            return settle(arguments, ask({ setting: name, op: "set", value: details.value }).then(function () {}));
          },
          clear: function () {
            if (isFramedInWebPage()) return settle(arguments, Promise.reject(new Error(framedRefusal)));
            return settle(arguments, ask({ setting: name, op: "clear" }).then(function () {}, function () {}));
          },
          onChange: change.event
        };
      }

      if (asked("privacy")) {
        var privacy = supply(api, "privacy", {});
        if (privacy) {
          var services = supply(privacy, "services", {});
          supply(privacy, "network", {});
          supply(privacy, "websites", {});
          if (services) {
            // This browser saves passwords and fills cards and addresses by
            // itself, as Chrome does by default. Only password saving may be
            // held by an extension: a password manager asks its own save
            // question, and has nothing to put in place of card and address
            // autofill.
            var transport = settingsTransport();
            supply(services, "passwordSavingEnabled", transport
              ? controllableSetting("services.passwordSavingEnabled", true, transport)
              : uncontrollableSetting(true));
            supply(services, "autofillCreditCardEnabled", uncontrollableSetting(true));
            supply(services, "autofillAddressEnabled", uncontrollableSetting(true));
          }
        }
      }

      var navigation = api.webNavigation;
      if (asked("webNavigation") && navigation) {
        // WebKit reports none of these, so they never fire here.
        supply(navigation, "onHistoryStateUpdated", makeEvent().event);
        supply(navigation, "onReferenceFragmentUpdated", makeEvent().event);
        supply(navigation, "onCreatedNavigationTarget", makeEvent().event);
        // tabs.onReplaced reports the same swap. It is listened to only once
        // the extension listens, and then at once, so a worker woken for the
        // event still has the listener in place.
        if (navigation.onTabReplaced === undefined) {
          var replaced = makeEvent(function () {
            var tabs = api.tabs;
            if (!tabs || !tabs.onReplaced || typeof tabs.onReplaced.addListener !== "function") return;
            try {
              tabs.onReplaced.addListener(function (addedTabId, removedTabId) {
                replaced.fire({ replacedTabId: removedTabId, tabId: addedTabId, timeStamp: Date.now() });
              });
            } catch (e) {}
          });
          supply(navigation, "onTabReplaced", replaced.event);
        }
      }

      // An extension page framed inside a web page runs in that page's web
      // content process, which WebKit does not trust with privileged
      // messages. It still offers action.openPopup() there, and when the
      // frame calls it WebKit treats the message as invalid and kills the
      // whole page's process: the tab goes blank and reloads. So in such a
      // frame openPopup asks the background, which may send it, to open the
      // popup for the frame's window instead.
      var relayKey = "__browserCompatOpenPopup";
      var openPopupRelayed = false;
      var isWorker = typeof window === "undefined";
      function isFramedInWebPage() {
        if (isWorker || window.top === window) return false;
        try { return window.top.location.origin !== location.origin; } catch (e) { return true; }
      }
      function isBackground() {
        if (isWorker) return true;
        try {
          var background = api.runtime.getManifest().background || {};
          if (background.page && location.pathname === "/" + background.page.replace(/^\/+/, "")) return true;
          return !!(api.extension && api.extension.getBackgroundPage && api.extension.getBackgroundPage() === window);
        } catch (e) { return false; }
      }
      var action = api.action;
      if (action && typeof action.openPopup === "function" && api.runtime.onMessage) {
        if (isFramedInWebPage()) {
          try {
            Object.defineProperty(action, "openPopup", {
              configurable: true, enumerable: true, writable: true,
              value: function (options) {
                var args = arguments;
                var request = {};
                request[relayKey] = true;
                if (options && typeof options === "object" && typeof options.windowId === "number") request.windowId = options.windowId;
                var outcome = new Promise(function (resolve, reject) {
                  api.runtime.sendMessage(request, function (reply) {
                    var lastError = api.runtime.lastError;
                    if (lastError) reject(new Error(lastError.message));
                    else if (!reply) reject(new Error("The extension's popup could not be opened."));
                    else if (reply.error) reject(new Error(reply.error));
                    else resolve();
                  });
                });
                var callback = args.length && typeof args[args.length - 1] === "function" ? args[args.length - 1] : null;
                if (!callback) return outcome;
                outcome.then(function () { callback(); }, function () { callback(); });
                return undefined;
              }
            });
            openPopupRelayed = true;
          } catch (e) {}
        } else if (isBackground()) {
          api.runtime.onMessage.addListener(function (message, sender, sendResponse) {
            if (!message || message[relayKey] !== true) return undefined;
            var windowId = typeof message.windowId === "number" ? message.windowId
              : sender && sender.tab && typeof sender.tab.windowId === "number" ? sender.tab.windowId : undefined;
            Promise.resolve()
              .then(function () { return action.openPopup(windowId === undefined ? undefined : { windowId: windowId }); })
              .then(function () { sendResponse({}); }, function (e) { sendResponse({ error: String(e && e.message || e) }); });
            return true;
          });
        }
      }

      // The same fault for every other API whose UI-process handler only
      // accepts a privileged message (WebKit 6e6e3c07,
      // WebExtensionContext.messages.in: isLoadedAndPrivilegedMessage and the
      // validators built on it). In a frame inside a web page each of these
      // fails with an error here instead of killing the page. Events,
      // runtime, storage, permissions and i18n are not privileged and work
      // as they are.
      if (isFramedInWebPage()) {
        var actionMethods = ["disable", "enable", "getBadgeBackgroundColor", "getBadgeText", "getPopup", "getTitle", "isEnabled",
          "openPopup", "setBadgeBackgroundColor", "setBadgeText", "setIcon", "setPopup", "setTitle"];
        var privileged = {
          action: actionMethods, browserAction: actionMethods, pageAction: actionMethods,
          alarms: ["clear", "clearAll", "create", "get", "getAll"],
          bookmarks: ["create", "get", "getChildren", "getRecent", "getSubTree", "getTree", "move", "remove", "removeTree", "search", "update"],
          commands: ["getAll"],
          contextMenus: ["create", "remove", "removeAll", "update"],
          menus: ["create", "remove", "removeAll", "update"],
          cookies: ["get", "getAll", "getAllCookieStores", "remove", "set"],
          declarativeNetRequest: ["getDynamicRules", "getEnabledRulesets", "getMatchedRules", "getSessionRules",
            "setExtensionActionOptions", "updateDynamicRules", "updateEnabledRulesets", "updateSessionRules"],
          notifications: ["clear", "create", "getAll", "getPermissionLevel", "update"],
          offscreen: ["closeDocument", "createDocument", "hasDocument"],
          scripting: ["executeScript", "getRegisteredContentScripts", "insertCSS", "registerContentScripts", "removeCSS",
            "unregisterContentScripts", "updateContentScripts"],
          sidebarAction: ["close", "getPanel", "getTitle", "isOpen", "open", "setIcon", "setPanel", "setTitle", "toggle"],
          sidePanel: ["close", "getLayout", "getOptions", "getPanelBehavior", "open", "setOptions", "setPanelBehavior"],
          tabs: ["captureVisibleTab", "connect", "create", "detectLanguage", "duplicate", "executeScript", "get", "getCurrent",
            "getSelected", "getZoom", "goBack", "goForward", "insertCSS", "move", "query", "reload", "remove", "removeCSS",
            "sendMessage", "setZoom", "toggleReaderMode", "update"],
          webNavigation: ["getAllFrames", "getFrame"],
          windows: ["create", "get", "getAll", "getCurrent", "getLastFocused", "remove", "update"]
        };
        // These return their result at once rather than through a promise.
        var returnsAtOnce = { "tabs.connect": true, "contextMenus.create": true, "menus.create": true };
        Object.keys(privileged).forEach(function (family) {
          var target;
          try { target = api[family]; } catch (e) { return; }
          if (!target || typeof target !== "object") return;
          privileged[family].forEach(function (name) {
            if (family === "action" && name === "openPopup" && openPopupRelayed) return;
            if (typeof target[name] !== "function") return;
            var problem = "chrome." + family + "." + name + "() is not available in an extension page shown inside a web page.";
            var refusal = returnsAtOnce[family + "." + name]
              ? function () { throw new Error(problem); }
              : function () { return settle(arguments, Promise.reject(new Error(problem))); };
            try {
              Object.defineProperty(target, name, { configurable: true, enumerable: true, writable: true, value: refusal });
            } catch (e) {}
          });
        });
      }
    })();

    """#
}
