import AppKit
import WebKit

/// Process-wide, cross-tab registry for the generic page<->native message
/// channel -- the WebKit equivalent of CEF's window.cefQuery, built on
/// WKScriptMessageHandlerWithReply (confirmed present, a genuine two-way
/// channel unlike plain WKScriptMessageHandler's fire-and-forget). Global,
/// matching EngineTab.respondToPageMessage's own documented contract that
/// `requestId` is global across every tab, not scoped to whichever tab
/// receives the eventual response call.
private enum PageMessageBridge {
    private struct Pending {
        let owner: ObjectIdentifier
        let reply: (Bool, Int, String) -> Void
    }

    private static var nextRequestId: Int64 = 1
    private static var pendingReplies: [Int64: Pending] = [:]

    static func nextId(owner: WebKitTab, reply: @escaping (Bool, Int, String) -> Void) -> Int64 {
        let id = nextRequestId
        nextRequestId += 1
        pendingReplies[id] = Pending(owner: ObjectIdentifier(owner), reply: reply)
        return id
    }

    static func respond(requestId: Int64, success: Bool, response: String) {
        guard let pending = pendingReplies.removeValue(forKey: requestId) else { return }
        // BRWPageMessageRouter reports every native failure as code 0.
        pending.reply(success, 0, response)
    }

    /// A WKScriptMessageHandlerWithReply reply block must be called exactly
    /// once, so a closing tab fails whatever it still owes rather than
    /// leaking the blocks -- the same outcome CEF's router gives a query
    /// whose browser closes.
    static func cancelAll(owner: WebKitTab) {
        let ownerId = ObjectIdentifier(owner)
        for (id, pending) in pendingReplies where pending.owner == ownerId {
            pendingReplies.removeValue(forKey: id)
            pending.reply(false, PageMessageShim.canceledErrorCode, PageMessageShim.canceledErrorMessage)
        }
    }
}

/// Defines `window.cefQuery` / `window.cefQueryCancel` on WebKit, so every
/// page script written against CEF's message router (password detection,
/// autofill, reading-list capture, the notification override, the start
/// page's gear) runs unchanged on this engine.
///
/// Mirrors CefMessageRouterRendererSide as configured by
/// BRWPageMessageRouter::Config(): injected into every frame (the renderer
/// router binds both functions into every V8 context, subframes included),
/// defined read-only, non-enumerable and non-deletable (the attributes CEF
/// binds them with), `cefQuery({request, persistent, onSuccess, onFailure})`
/// returns a numeric query id, `onSuccess(response)` and
/// `onFailure(errorCode, errorMessage)` are called asynchronously, and
/// `cefQueryCancel(id)` stops any further callback for that query.
///
/// The trust model is CEF's: any script in any frame can already send a
/// query there, so exposing the same entry point here grants a page nothing
/// new, and native handlers get only the request string, never a claim
/// about who sent it. `postMessage` is captured at document start, so later
/// page tampering with `window.webkit` cannot redirect or intercept the
/// channel.
enum PageMessageShim {
    /// CEF's own `kCanceledErrorCode`/`kCanceledErrorMessage`, used when no
    /// handler takes a query or its browser goes away first.
    static let canceledErrorCode = -1
    static let canceledErrorMessage = "The query has been canceled"

    static func source(handlerName: String) -> String {
        """
        (function() {
          var handlers = window.webkit && window.webkit.messageHandlers;
          var channel = handlers && handlers[\(jsonString(handlerName))];
          if (!channel || window.cefQuery) { return; }
          var post = channel.postMessage.bind(channel);
          var nextId = 1;
          var live = Object.create(null);

          function cefQuery(params) {
            if (!params || typeof params !== 'object' || typeof params.request !== 'string') {
              throw new TypeError('Invalid arguments; expecting a single object with a string request');
            }
            if ((params.onSuccess !== undefined && typeof params.onSuccess !== 'function') ||
                (params.onFailure !== undefined && typeof params.onFailure !== 'function')) {
              throw new TypeError('Invalid arguments; onSuccess and onFailure must be functions');
            }
            var id = nextId++;
            var persistent = !!params.persistent;
            var onSuccess = params.onSuccess;
            var onFailure = params.onFailure;
            live[id] = true;
            post(params.request).then(function(reply) {
              if (!live[id]) { return; }
              if (reply && reply.ok === true) {
                if (!persistent) { delete live[id]; }
                if (onSuccess) { onSuccess(typeof reply.response === 'string' ? reply.response : ''); }
              } else {
                delete live[id];
                if (onFailure) {
                  onFailure(reply && typeof reply.code === 'number' ? reply.code : \(canceledErrorCode),
                            reply && typeof reply.response === 'string' ? reply.response : \(jsonString(canceledErrorMessage)));
                }
              }
            }, function(error) {
              if (!live[id]) { return; }
              delete live[id];
              if (onFailure) { onFailure(\(canceledErrorCode), String((error && error.message) || error)); }
            });
            return id;
          }

          function cefQueryCancel(id) {
            delete live[id];
          }

          Object.defineProperty(window, 'cefQuery', { value: cefQuery, writable: false, enumerable: false, configurable: false });
          Object.defineProperty(window, 'cefQueryCancel', { value: cefQueryCancel, writable: false, enumerable: false, configurable: false });
        })();
        """
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        return encoded
    }
}

/// The `Version/x Safari/y` suffix WebKit appends to its own
/// `Mozilla/5.0 (Macintosh; ...) AppleWebKit/605.1.15 (KHTML, like Gecko)`
/// prefix, so the full user agent has exactly the installed Safari's shape.
/// Without it, sites that refuse embedded web views -- Google sign-in first
/// among them -- see this browser as one.
enum SafariUserAgent {
    /// Safari froze this token alongside the AppleWebKit one; it no longer
    /// tracks the real WebKit build.
    private static let frozenSafariToken = "605.1.15"

    static let applicationName = "Version/\(installedSafariVersion() ?? fallbackVersion()) Safari/\(frozenSafariToken)"

    private static func installedSafariVersion() -> String? {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            ?? URL(fileURLWithPath: "/Applications/Safari.app")
        guard let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty,
              version.allSatisfy({ $0.isNumber || $0 == "." })
        else { return nil }
        return version
    }

    /// Since macOS 26, Safari's major version equals the OS's; 18 is the
    /// last Safari the systems before that received.
    private static func fallbackVersion() -> String {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return major >= 26 ? "\(major).0" : "18.0"
    }
}

extension WebKitTab: WKScriptMessageHandlerWithReply {
    func executeJavaScript(_ code: String) {
        webView.evaluateJavaScript(code) { _, error in
            if let error {
                NSLog("Browser: WebKit executeJavaScript error: %@", error.localizedDescription)
            }
        }
    }

    /// Genuinely different mechanism from CEF's, with genuinely different
    /// coverage: WebKit has no `CefBrowserHost::DownloadImage` equivalent
    /// (nothing public hands back the bytes of an already-decoded image the
    /// page loaded), so this fetches inside the page instead. That still
    /// carries the page's cookies -- `credentials: "include"` on a fetch
    /// issued by the document itself -- but it is subject to CORS, unlike
    /// the CEF path: a cross-origin image whose host sends no
    /// `Access-Control-Allow-Origin` fails here and succeeds there.
    ///
    /// `httpStatusCode` is the real response status when the fetch got far
    /// enough to have one, and 0 otherwise.
    func downloadImage(url: String, completion: @escaping (Data?, Int) -> Void) {
        let encoded = String(data: (try? JSONEncoder().encode(url)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        let script = """
        (async () => {
          const response = await fetch(\(encoded), { credentials: "include" });
          const buffer = await response.arrayBuffer();
          let binary = "";
          const bytes = new Uint8Array(buffer);
          for (let i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]); }
          return { status: response.status, base64: btoa(binary) };
        })()
        """
        webView.callAsyncJavaScript(script, in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                guard let dictionary = value as? [String: Any],
                      let base64 = dictionary["base64"] as? String,
                      let data = Data(base64Encoded: base64)
                else {
                    completion(nil, 0)
                    return
                }
                completion(data, dictionary["status"] as? Int ?? 0)
            case .failure(let error):
                NSLog("Browser: WebKit downloadImage failed: %@", error.localizedDescription)
                completion(nil, 0)
            }
        }
    }

    func getPageSource(completion: @escaping (String?) -> Void) {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
            if let error {
                NSLog("Browser: WebKit getPageSource error: %@", error.localizedDescription)
                completion(nil)
                return
            }
            completion(result as? String)
        }
    }

    func respondToPageMessage(requestId: Int64, success: Bool, response: String) {
        PageMessageBridge.respond(requestId: requestId, success: success, response: response)
    }

    /// Adds the cefQuery shim and the native end of its channel to a new
    /// tab's content controller. Both live in the page content world, like
    /// every page script that calls cefQuery.
    func installPageMessageBridge(into userContentController: WKUserContentController, handlerName: String) {
        userContentController.addScriptMessageHandler(self, contentWorld: .page, name: handlerName)
        userContentController.addUserScript(WKUserScript(
            source: PageMessageShim.source(handlerName: handlerName),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .page))
    }

    func cancelPendingPageMessages() {
        PageMessageBridge.cancelAll(owner: self)
    }

    // MARK: - WKScriptMessageHandlerWithReply (window.cefQuery equivalent)

    /// Always replies with `{ok, code, response}` rather than through the
    /// reply block's error string, so the shim can hand callers CEF's exact
    /// `onFailure(errorCode, errorMessage)` pair.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        let reply: (Bool, Int, String) -> Void = { ok, code, response in
            replyHandler(["ok": ok, "code": code, "response": response], nil)
        }
        guard let request = message.body as? String else {
            reply(false, PageMessageShim.canceledErrorCode, "invalid page message body")
            return
        }
        guard let delegate else {
            reply(false, PageMessageShim.canceledErrorCode, PageMessageShim.canceledErrorMessage)
            return
        }
        let requestId = PageMessageBridge.nextId(owner: self, reply: reply)
        delegate.engineTabDidReceivePageMessage(request, requestId: requestId)
    }
}
