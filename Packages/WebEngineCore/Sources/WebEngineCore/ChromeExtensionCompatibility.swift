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
/// Only extensions whose manifest asks for a permission in
/// `suppliedPermissions` are touched, and preparing one twice changes
/// nothing the second time.
public enum ChromeExtensionCompatibility {
    public static let shimFile = "__browser_chrome_compat.js"
    public static let workerFile = "__browser_background.js"

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

      if (asked("privacy")) {
        var privacy = supply(api, "privacy", {});
        if (privacy) {
          var services = supply(privacy, "services", {});
          supply(privacy, "network", {});
          supply(privacy, "websites", {});
          if (services) {
            // This browser saves passwords and fills cards and addresses by
            // itself, as Chrome does by default.
            supply(services, "passwordSavingEnabled", uncontrollableSetting(true));
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
    })();

    """#
}
