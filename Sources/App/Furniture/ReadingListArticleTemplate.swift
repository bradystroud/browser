import Foundation

/// Renders a saved article back onto the screen with no network at all
/// (browser-56p) -- the reading half of offline capture.
///
/// The document is delivered as a base64 `data:` URL, the same vehicle the
/// start page uses (see StartPageRenderer). That is what makes it genuinely
/// offline: there is no request, no cache lookup and no origin involved,
/// just a document handed straight to the engine.
enum ReadingListArticleTemplate {
    /// **The captured markup is untrusted.** It came from an arbitrary site
    /// and is stored verbatim, so rendering it inside a document of ours
    /// would otherwise run whatever it carries -- a surviving `<script>`,
    /// or far more likely an inline `onerror=` on an image that fails to
    /// load, which is exactly what happens when a saved article is read
    /// offline. Readability strips scripts itself, but "the extractor
    /// probably removed it" is not a security boundary.
    ///
    /// `script-src` is absent from this policy, so `default-src 'none'`
    /// governs it: no external scripts, no inline `<script>`, and no inline
    /// event handlers, which CSP blocks along with everything else under
    /// script-src unless 'unsafe-inline' is granted. `style-src
    /// 'unsafe-inline'` is granted, because the stylesheet below is inline
    /// and articles carry inline `style` attributes; CSS cannot execute
    /// anything. Images and media are allowed from anywhere so that a
    /// saved article still shows its pictures when the machine is online --
    /// they are the one part of a captured page that is not stored locally.
    /// `base-uri 'none'` keeps a captured `<base>` from re-pointing every
    /// relative link in the article; `sanitized(_:)` removes such tags
    /// before they reach the page as well.
    private static let contentSecurityPolicy = [
        "default-src 'none'",
        "img-src * data: blob:",
        "media-src * data: blob:",
        "style-src 'unsafe-inline'",
        "font-src * data:",
        "form-action 'none'",
        "base-uri 'none'",
    ].joined(separator: "; ")

    static func dataURL(for item: ReadingListItem, content: String) -> String {
        let base64 = Data(html(for: item, content: content).utf8).base64EncodedString()
        return "data:text/html;charset=utf-8;base64,\(base64)"
    }

    static func html(for item: ReadingListItem, content: String) -> String {
        let scale = ReaderFontSizePreference.current.scale
        let byline = item.byline.isEmpty
            ? ""
            : "<p class=\"brw-reader-byline\">\(escape(item.byline))</p>"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(escape(contentSecurityPolicy))">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(item.title))</title>
        <style>\(ReaderTemplate.css(fontScale: scale))\(supplementalCSS)</style>
        </head><body>
        <article>
        <h1 class="brw-reader-title">\(escape(item.title))</h1>
        \(byline)
        <p class="brw-reading-list-source"><a href="\(escape(item.url))">\(escape(displayHost(item.url)))</a>\
         \u{00B7} saved offline</p>
        <div class="brw-reader-content">\(sanitized(content))</div>
        </article>
        </body></html>
        """
    }

    /// One rule on top of Reader mode's stylesheet, for the line that says
    /// where the article came from. Everything else is deliberately shared,
    /// so a saved article and a Reader-mode article read identically.
    private static let supplementalCSS = """

    .brw-reading-list-source {
      font-size: 0.8em; color: #767676; margin: -0.5em 0 2.5em;
    }
    .brw-reading-list-source a { color: inherit; }
    """

    /// Removes every `<meta>` and `<base>` tag from captured markup. An
    /// article body never needs either, and both act on the whole document
    /// wherever they appear: `<meta http-equiv>` can redirect the page or
    /// set its own policies, and `<base>` changes where relative links go.
    /// Applied when rendering rather than when saving, so articles stored
    /// before this existed are covered too. The pattern skips over quoted
    /// attribute values, so a `>` inside one does not end the tag early.
    static func sanitized(_ content: String) -> String {
        content.replacingOccurrences(
            of: #"<\s*(meta|base)\b(?:[^>"']|"[^"]*"|'[^']*')*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// The host on its own reads better than a full URL in a byline, and a
    /// URL that will not parse still has to render something -- so it falls
    /// back to the raw string rather than an empty link.
    private static func displayHost(_ url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return url }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Escapes a plain string for an HTML text or attribute context. Only
    /// ever applied to the title, byline and URL -- never to the captured
    /// article markup, which is already serialized HTML and would be
    /// destroyed by escaping.
    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
