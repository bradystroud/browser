import Foundation

/// Builds the CSS/JS for Reader mode's client-side transformation. The
/// entire extraction-and-render pipeline runs inside the page's own JS
/// context via a single fire-and-forget executeJavaScript(_:) call (see
/// BRWBrowser.h's own doc comment on why that method has no result path at
/// all) -- Readability.js parses the article and the wrapper script below
/// writes a brand new document over the live DOM with `document.write`,
/// entirely in-page. Nothing here needs a result back from JS into native
/// code except the one boolean "does this page look readerable" signal,
/// handled separately by `readerableProbeScript`/`isMarkedReaderable`.
enum ReaderTemplate {
    private static let readerableMarkerAttribute = "data-brw-readerable"

    static func css(fontScale: Double) -> String {
        """
        :root { --brw-font-scale: \(fontScale); }
        html, body { margin: 0; padding: 0; }
        body {
          font-family: Georgia, 'Times New Roman', serif;
          font-size: calc(19px * var(--brw-font-scale));
          line-height: 1.6;
          max-width: 65ch;
          margin: 0 auto;
          padding: 56px 24px 96px;
          color: #1a1a1a;
          background: #fdfdfd;
          -webkit-font-smoothing: antialiased;
        }
        @media (prefers-color-scheme: dark) {
          body { color: #e2e2e2; background: #1c1c1e; }
          a { color: #6ab0f3; }
        }
        a { color: #0066cc; }
        .brw-reader-title { font-size: 1.8em; line-height: 1.25; margin: 0 0 8px; }
        .brw-reader-byline { color: #767676; font-size: 0.85em; margin: 0 0 2em; }
        .brw-reader-content img, .brw-reader-content video, .brw-reader-content iframe {
          max-width: 100%; height: auto;
        }
        .brw-reader-content pre {
          overflow-x: auto; padding: 12px; background: rgba(127,127,127,0.12); border-radius: 6px;
        }
        .brw-reader-content blockquote {
          border-left: 3px solid rgba(127,127,127,0.4); margin: 1em 0; padding: 0.2em 1em; color: #767676;
        }
        """
    }

    /// The activation script: Readability.js's own vendored source, plus a
    /// small wrapper that extracts the article and replaces the live
    /// document via `document.write`. `article.content` (the extracted
    /// article body) is inserted as-is -- it's already-serialized HTML
    /// markup and must NOT be escaped; `article.title`/`article.byline` ARE
    /// escaped (via a throwaway element's textContent round-trip) since
    /// they're plain strings being placed into an HTML context.
    static func activationScript(fontScale: Double) -> String {
        ReaderScripts.readabilityJS + "\n" + """
        (function() {
          function brwEscapeHTML(s) {
            var d = document.createElement('div');
            d.appendChild(document.createTextNode(s || ''));
            return d.innerHTML;
          }
          try {
            var docClone = document.cloneNode(true);
            var article = new Readability(docClone).parse();
            if (!article || !article.content) { return; }
            var titleHTML = brwEscapeHTML(article.title || document.title || '');
            var bylineHTML = article.byline ? brwEscapeHTML(article.byline) : '';
            var css = \(jsonString(css(fontScale: fontScale)));
            var html = '<!doctype html><html><head><meta charset="utf-8">' +
              '<meta name="viewport" content="width=device-width, initial-scale=1">' +
              '<style>' + css + '</style></head><body>' +
              '<article><h1 class="brw-reader-title">' + titleHTML + '</h1>' +
              (bylineHTML ? '<p class="brw-reader-byline">' + bylineHTML + '</p>' : '') +
              '<div class="brw-reader-content">' + article.content + '</div>' +
              '</article></body></html>';
            document.open();
            document.write(html);
            document.close();
          } catch (e) {
            console.error('Browser Reader mode failed:', e);
          }
        })();
        """
    }

    /// Adjusts font size on an already-activated reader page without
    /// regenerating/re-parsing the article -- just updates the CSS custom
    /// property the stylesheet above keys font-size off of.
    static func setFontScaleScript(_ scale: Double) -> String {
        "document.documentElement.style.setProperty('--brw-font-scale', '\(scale)');"
    }

    /// Probe script: runs Mozilla's own isProbablyReaderable() heuristic
    /// (the same one Firefox's real Reader Mode uses to decide whether to
    /// show its own icon) and sets a marker attribute on `<html>`.
    /// ReaderModeController reads this back via BRWBrowser.getPageSource,
    /// since executeJavaScript(_:) has no result path of its own -- see
    /// docs/ai-tasks/reader-mode-notes.md for the full reasoning.
    static let readerableProbeScript: String = ReaderScripts.readerableJS + "\n" + """
    (function() {
      try {
        var readerable = isProbablyReaderable(document);
        document.documentElement.setAttribute('\(readerableMarkerAttribute)', readerable ? 'true' : 'false');
      } catch (e) {
        document.documentElement.setAttribute('\(readerableMarkerAttribute)', 'false');
      }
    })();
    """

    static func isMarkedReaderable(inSource source: String) -> Bool {
        source.contains("\(readerableMarkerAttribute)=\"true\"")
    }

    private static func jsonString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s), let json = String(data: data, encoding: .utf8) else {
            return "''"
        }
        return json
    }
}
