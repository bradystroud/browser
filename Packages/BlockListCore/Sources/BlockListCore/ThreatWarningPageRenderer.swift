import Foundation

/// Renders the "this site may be dangerous" interstitial shown in place of
/// a blocked top-level navigation to a known threat-list host
/// (browser-12m.6). Same data: URL technique as `Sources/App/StartPage/
/// StartPageRenderer` (see that file's own doc comment for why a data: URL
/// rather than a custom CEF scheme/loadHTML API) -- reimplemented here
/// rather than shared with it directly, since this needs zero app-specific
/// state (no `ProfileManager`, no per-profile settings beyond the two
/// strings passed in), so it belongs in this pure Swift/Foundation package
/// like every other `BlockListCore` type, rather than `Sources/App`. The
/// bridge calls this (via a block registered through `BRWThreatList`,
/// since C++ can't import a Swift package directly) only ever from the UI
/// thread, so it being pure/stateless also means it's trivially safe to
/// call from there.
///
/// "Go back" is a plain `history.back()` button and "Continue anyway" is a
/// plain `<a href>` to `ThreatWarningLink`'s marker URL -- both handled
/// entirely by the browser engine (or the bridge's own
/// `OnBeforeResourceLoad` interception of that one marker URL), with no
/// JS-to-native message channel needed for either.
public enum ThreatWarningPageRenderer {
    public static func dataURL(host: String, originalURL: String) -> String {
        let html = renderHTML(host: host, originalURL: originalURL)
        let base64 = Data(html.utf8).base64EncodedString()
        return "data:text/html;charset=utf-8;base64,\(base64)"
    }

    static func renderHTML(host: String, originalURL: String) -> String {
        let continueHref = ThreatWarningLink.continueURL(bypassing: originalURL)
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(css)</style>
        </head>
        <body>
        <main>
        <div class="icon">⚠️</div>
        <h1>This site may be dangerous</h1>
        <p><strong>\(escape(host))</strong> is on a known phishing/malware list. Continuing could expose you to malicious content or an attempt to steal your information.</p>
        <button class="primary" onclick="history.back()">Go Back</button>
        <p class="continue-row"><a href="\(escape(continueHref))">Continue anyway (unsafe)</a></p>
        </main>
        </body>
        </html>
        """
    }

    private static var css: String {
        """
        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100vh;
          background: linear-gradient(160deg, #8a1414 0%, #3d0505 100%);
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          color: #ffffff;
          display: flex;
          align-items: center;
          justify-content: center;
        }
        main {
          max-width: 480px;
          padding: 48px;
          text-align: center;
        }
        .icon { font-size: 48px; margin-bottom: 16px; }
        h1 { font-size: 22px; margin: 0 0 16px; }
        p { line-height: 1.5; color: rgba(255, 255, 255, 0.88); }
        .primary {
          margin-top: 20px;
          padding: 12px 32px;
          border: none;
          border-radius: 8px;
          background: #ffffff;
          color: #8a1414;
          font-size: 14px;
          font-weight: 600;
          cursor: pointer;
        }
        .continue-row { margin-top: 28px; }
        .continue-row a {
          color: rgba(255, 255, 255, 0.55);
          font-size: 12px;
          text-decoration: underline;
        }
        """
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
