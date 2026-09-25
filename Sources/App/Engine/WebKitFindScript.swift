/// The match-counting half of WebKitTab.find(...). WKWebView.find reports only
/// found / not found, so the count and the active match's ordinal come from
/// walking the page's text here.
///
/// Run through callAsyncJavaScript as a function body, in the
/// `.defaultClient` content world so a page that redefines DOM builtins
/// cannot skew the count. Arguments: `query` (the find-bar text) and
/// `matchCase`. Returns `[matchCount, selectedOrdinal]`, where
/// `selectedOrdinal` is the 1-based position of the match WebKit's own find
/// just selected, or 0 when the selection is not in any counted text node
/// (a form field, an iframe) and the caller has to track the ordinal itself.
///
/// Approximations, each of which errs toward the count WebKit's own find
/// would reach: whitespace runs are collapsed inside each text node (as
/// rendering does), text is joined across inline elements but split at
/// block boundaries, and only the main frame's visible text is counted.
enum WebKitFindScript {
    static let countMatches = """
    const fold = (s) => (matchCase ? s : s.toLowerCase()).replace(/\\s+/g, " ");
    const needle = fold(query);
    if (!needle) { return [0, 0]; }

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
    if (!root) { return [0, 0]; }
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
    if (matchStarts.length && selection && selection.rangeCount) {
      const range = selection.getRangeAt(0);
      const start = nodeStarts.get(range.startContainer);
      if (start !== undefined) {
        const offset = start + fold(range.startContainer.data.slice(0, range.startOffset)).length;
        const index = matchStarts.findIndex((m) => m >= offset);
        selectedOrdinal = index === -1 ? matchStarts.length : index + 1;
      }
    }
    return [matchStarts.length, selectedOrdinal];
    """
}
