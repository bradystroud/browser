import WebKit

/// The match-counting half of WebKitTab.find(...). WKWebView.find reports only
/// found / not found, so the count and the active match's ordinal come from
/// walking the page's text here, once in the main frame and once in every
/// iframe WebKitFindFrameRegistry knows about (same-origin or not: each walk
/// runs inside its own frame).
///
/// Run through callAsyncJavaScript as a function body, in the
/// `.defaultClient` content world so a page that redefines DOM builtins
/// cannot skew the count. Arguments: `query` (the find-bar text) and
/// `matchCase`. Returns
/// `[matchCount, selectedOrdinal, framePath, visibilityState, isZeroSize]`:
///
/// - `selectedOrdinal` is the 1-based position, within this frame, of the
///   match WebKit's own find just selected, or 0 when this frame holds no
///   non-empty selection in counted text (a form field, another frame).
/// - `framePath` is the frame's index at each level from the top window
///   down (`[]` for the main frame), read through `parent[i] === window`,
///   which cross-origin WindowProxy access allows. Sorting frames by it
///   gives frame-tree preorder, the order WebKit's find visits them in: all
///   of one frame's matches, then its child frames' in document order.
/// - `visibilityState` and `isZeroSize` let the caller drop a frame of a
///   page kept in the back-forward cache and a `display: none` iframe.
///
/// Approximations, each of which errs toward the count WebKit's own find
/// would reach: whitespace runs are collapsed inside each text node (as
/// rendering does), and text is joined across inline elements but split at
/// block boundaries.
enum WebKitFindScript {
    static let countMatches = """
    const framePath = [];
    try {
      for (let w = window; w !== w.parent; w = w.parent) {
        const parent = w.parent;
        let index = -1;
        for (let i = 0; i < parent.length; i++) {
          if (parent[i] === w) { index = i; break; }
        }
        framePath.unshift(index);
      }
    } catch (e) {}
    const done = (count, selected) =>
      [count, selected, framePath, document.visibilityState, window.innerWidth === 0 || window.innerHeight === 0];

    const fold = (s) => (matchCase ? s : s.toLowerCase()).replace(/\\s+/g, " ");
    const needle = fold(query);
    if (!needle) { return done(0, 0); }

    const skipped = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "HEAD", "TITLE"]);
    const inline = new Set(["A", "ABBR", "B", "BDI", "BDO", "CITE", "CODE", "DATA", "DFN", "EM", "FONT",
      "I", "KBD", "LABEL", "MARK", "Q", "S", "SAMP", "SMALL", "SPAN", "STRONG", "SUB", "SUP", "TIME",
      "U", "VAR", "DEL", "INS"]);
    const visibility = new Map();
    const isVisible = (el) => {
      let v = visibility.get(el);
      if (v === undefined) {
        v = typeof el.checkVisibility === "function"
          ? el.checkVisibility({ visibilityProperty: true })
          : el.getClientRects().length > 0;
        visibility.set(el, v);
      }
      return v;
    };
    const blockOf = (el) => {
      while (el && inline.has(el.tagName) && el.parentElement) { el = el.parentElement; }
      return el;
    };

    const root = document.body || document.documentElement;
    if (!root) { return done(0, 0); }
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        const parent = node.parentElement;
        if (!parent || !node.data || skipped.has(parent.tagName) || !isVisible(parent)) {
          return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });

    let text = "";
    const nodeStarts = new Map();
    let previousBlock = null;
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const block = blockOf(node.parentElement);
      if (previousBlock && block !== previousBlock) { text += "\\n"; }
      previousBlock = block;
      nodeStarts.set(node, text.length);
      text += fold(node.data);
    }

    const matchStarts = [];
    for (let i = text.indexOf(needle); i !== -1; i = text.indexOf(needle, i + needle.length)) {
      matchStarts.push(i);
    }

    let selectedOrdinal = 0;
    const selection = window.getSelection();
    if (matchStarts.length && selection && selection.rangeCount && !selection.getRangeAt(0).collapsed) {
      const range = selection.getRangeAt(0);
      const start = nodeStarts.get(range.startContainer);
      if (start !== undefined) {
        const offset = start + fold(range.startContainer.data.slice(0, range.startOffset)).length;
        const index = matchStarts.findIndex((m) => m >= offset);
        selectedOrdinal = index === -1 ? matchStarts.length : index + 1;
      }
    }
    return done(matchStarts.length, selectedOrdinal);
    """

    /// Injected into every frame at document start. Each iframe document
    /// announces itself with a token of its own; a new main-frame document
    /// resets the list, which relies on its message arriving before its own
    /// iframes' -- true while a page's frames share one web content process. A page restored from the back-forward cache runs no
    /// user scripts, so its iframes announce themselves again on `pageshow`.
    static let registerFrame = """
    (() => {
      const token = Math.random().toString(36).slice(2) + Date.now().toString(36);
      const post = (kind) => {
        try { window.webkit.messageHandlers.\(WebKitFindFrameRegistry.handlerName).postMessage({ kind, token }); } catch (e) {}
      };
      if (window === window.top) { post("main"); return; }
      post("frame");
      window.addEventListener("pageshow", (event) => { if (event.persisted) { post("frame"); } });
    })();
    """
}

/// The iframes WebKitTab.find counts in. WKWebView has no public way to
/// enumerate a page's frames, but a message from a user script carries the
/// WKFrameInfo of the frame that sent it, and callAsyncJavaScript can run in
/// exactly that frame, cross-origin included. Holds no reference back to
/// the tab or web view, so the user content controller retaining it as a
/// message handler makes no cycle.
///
/// Entries can go stale (a removed iframe, a navigated one), so the find
/// code drops any frame whose script fails or times out and keeps one entry
/// per frame path. Handler and script live in `.defaultClient`, out of the
/// page's reach, so a page cannot forge or suppress registrations.
final class WebKitFindFrameRegistry: NSObject, WKScriptMessageHandler {
    static let handlerName = "brwFindFrame"

    private(set) var frames: [String: WKFrameInfo] = [:]

    func install(into userContentController: WKUserContentController) {
        userContentController.add(self, contentWorld: .defaultClient, name: Self.handlerName)
        userContentController.addUserScript(WKUserScript(
            source: WebKitFindScript.registerFrame,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .defaultClient
        ))
    }

    func remove(tokens: [String]) {
        tokens.forEach { frames.removeValue(forKey: $0) }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String,
              let token = body["token"] as? String else { return }
        if kind == "main", message.frameInfo.isMainFrame {
            frames.removeAll()
        } else if kind == "frame", !message.frameInfo.isMainFrame {
            frames[token] = message.frameInfo
        }
    }
}
