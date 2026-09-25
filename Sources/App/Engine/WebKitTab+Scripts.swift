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
    private static var nextRequestId: Int64 = 1
    private static var pendingReplies: [Int64: (Bool, String) -> Void] = [:]

    static func nextId(replyHandler: @escaping (Bool, String) -> Void) -> Int64 {
        let id = nextRequestId
        nextRequestId += 1
        pendingReplies[id] = replyHandler
        return id
    }

    static func respond(requestId: Int64, success: Bool, response: String) {
        guard let handler = pendingReplies.removeValue(forKey: requestId) else { return }
        handler(success, response)
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

    // MARK: - WKScriptMessageHandlerWithReply (window.cefQuery equivalent)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let request = message.body as? String else {
            replyHandler(nil, "invalid page message body")
            return
        }
        let requestId = PageMessageBridge.nextId { success, response in
            replyHandler(response, success ? nil : response)
        }
        delegate?.engineTabDidReceivePageMessage(request, requestId: requestId)
    }
}
