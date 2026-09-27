import Foundation

/// Page script behind EngineTab.setSiteStyleSheets(_:) -- one `<style>`
/// element per document, holding the stylesheet for whichever site the
/// document belongs to. Engine-neutral: each adapter decides *when* to run
/// it (WebKit from a document-start WKUserScript, CEF at load start), and
/// both run exactly this.
///
/// A sheet is keyed by a site (a registrable domain, `example.com`) and
/// applies to that host and every subdomain of it.
enum SiteStyleSheetScript {
    static let styleElementId = "__brw-site-style"

    /// The sheet for `host`, or "" when no site in `sheets` covers it.
    static func css(forHost host: String, in sheets: [String: String]) -> String {
        let host = host.lowercased()
        guard !host.isEmpty else { return "" }
        return sheets.first { site, _ in host == site || host.hasSuffix("." + site) }?.value ?? ""
    }

    /// Puts `css` in force in the current document, replacing whatever an
    /// earlier run put there; "" empties it. The element is emptied rather
    /// than removed because on WebKit two content worlds hold it: one
    /// world's removal would be undone by the other's keep-in-place guard.
    static func apply(css: String) -> String {
        "(\(applyFunction))(\(jsonLiteral(css)));"
    }

    /// Picks the sheet for the document's own `location.hostname` and puts
    /// it in force, emptying any earlier one when none matches. Used both at
    /// document start, where nobody yet knows where the tab will go, and to
    /// update a live document, where the embedder's idea of the URL may
    /// already be a pending navigation's.
    static func forDocumentLocation(sheets: [String: String]) -> String {
        """
        (function (sheets) {
          var host = String(location.hostname || '').toLowerCase();
          var css = '';
          if (host) {
            for (var site in sheets) {
              if (Object.prototype.hasOwnProperty.call(sheets, site) &&
                  (host === site || host.endsWith('.' + site))) { css = sheets[site]; break; }
            }
          }
          (\(applyFunction))(css);
        })(\(jsonLiteral(sheets)));
        """
    }

    /// At document start there may be no `<html>` element yet, so the sheet
    /// waits for the parser to create one. Once in place it is put back if
    /// the page later throws it away with the rest of the document's
    /// children -- some client-rendered pages rebuild `<head>` wholesale,
    /// and a hidden element coming back mid-session is the one failure this
    /// feature exists to prevent.
    private static let applyFunction = """
    function (css) {
      var id = '\(styleElementId)';
      var sheet = document.getElementById(id);
      if (!sheet) {
        if (!css) { return; }
        sheet = document.createElement('style');
        sheet.id = id;
      }
      if (sheet.textContent !== css) { sheet.textContent = css; }
      window.__brwSiteStyle = sheet;
      function place() {
        var current = window.__brwSiteStyle;
        if (!current || current.isConnected) { return !!document.documentElement; }
        var parent = document.head || document.documentElement;
        if (!parent) { return false; }
        parent.appendChild(current);
        return true;
      }
      if (!place()) {
        var waiting = new MutationObserver(function () {
          if (place()) { waiting.disconnect(); }
        });
        waiting.observe(document, { childList: true });
      }
      if (!window.__brwSiteStyleGuard && document.documentElement) {
        window.__brwSiteStyleGuard = new MutationObserver(place);
        window.__brwSiteStyleGuard.observe(document.documentElement, { childList: true, subtree: false });
        if (document.head) {
          window.__brwSiteStyleGuard.observe(document.head, { childList: true });
        }
      }
    }
    """

    private static func jsonLiteral<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}
