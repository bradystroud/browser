import Foundation

/// Renders the internal start page -- new tabs (⌘T) and the plain-launch
/// default window load this instead of about:blank/a real URL (see
/// Tab.swift's handling of the "about:blank" sentinel). Rendered as a
/// data: URL (base64-encoded HTML), not a custom scheme or a CEF loadHTML
/// API: no Reader-mode precedent had landed yet to coordinate conventions
/// with when this was written (worth reconciling later if Reader mode ends
/// up wanting the same thing), and a data: URL needs zero bridge/CEF
/// changes -- it flows through the exact same EngineTab.loadURL(_:) every
/// other navigation already uses.
///
/// Tile favicons come from FaviconLoader's per-profile on-disk cache, read
/// synchronously at render time and inlined as `data:` URIs. Inlining is
/// forced by the page being a `data:` URL itself: that is an opaque origin
/// with no access to `file:` resources, so an icon it can display has to
/// travel inside the document. The read is cache-hit-only and never fetches,
/// which is what keeps a purely local render local -- a host with nothing
/// cached falls back to the monogram (the title's first letter) rather than
/// making the page wait on a network round trip or re-render as icons land.
/// The fallback self-heals: ordinary browsing populates the cache, and
/// everything in Frequently Visited has been visited by definition.
enum StartPageRenderer {
    /// The tab title for every start-page tab, private or not -- also the
    /// generated HTML's own `<title>` element. Without a real `<title>`,
    /// Chromium falls back to formatting the page's own URL as its title
    /// (the same fallback real Chrome uses for any title-less page), which
    /// for this page is the full base64 `data:` URL -- confirmed live as
    /// the actual root cause of a tab showing that raw URL instead of a
    /// friendly name. Tab.swift's own `displayTitle`/`seedRestoredTitle`
    /// additionally guard against this same text with their own fixed
    /// fallback, so a stale/corrupted historical value (e.g. an already-
    /// persisted `session.json` from before this fix existed) can't
    /// resurface it either -- see those methods' own doc comments.
    static let tabTitle = "New Tab"

    static func dataURL(profileId: String, isPrivate: Bool = false) -> String {
        let html = isPrivate ? renderPrivateHTML() : renderHTML(profileId: profileId)
        let base64 = Data(html.utf8).base64EncodedString()
        return "data:text/html;charset=utf-8;base64,\(base64)"
    }

    private static func renderHTML(profileId: String) -> String {
        let settings = StartPageSettingsStore.load(forProfileId: profileId)
        // Content (and its empty-state wording) comes from StartPageSections,
        // shared with the omnibox's native focus panel (browser-5kq.9) -- this
        // file owns only the HTML presentation of it.
        let content = StartPageSections.build(
            profileId: profileId, settings: settings, historyKind: .frequentlyVisited
        )

        var sections = ""
        for built in content {
            // Actionable even when empty (browser-5kq.7) -- rather than
            // hiding the section entirely, which left no discoverable path
            // from "I'm on a page I like" to "it's in my Favorites grid."
            // Still says "yet," not e.g. "disabled," since a section is only
            // in this list at all when its own setting is on.
            sections += built.tiles.isEmpty
                ? emptySection(title: built.title, message: built.emptyMessage)
                : section(title: built.title, tiles: built.tiles, profileId: profileId)
        }
        if sections.isEmpty {
            // Both sections turned off in Settings -- the one case neither
            // per-section empty state above ever fires for.
            sections = "<p class=\"empty\">Nothing to show yet — browse a bit, or add a favorite.</p>"
        }

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(tabTitle))</title>
        <style>\(css(background: backgroundCSS(for: settings, profileId: profileId)))</style>
        </head>
        <body>
        <a class="gear" href="#" title="Start page settings" onclick="window.cefQuery({request: JSON.stringify({type: 'openStartPageSettings'}), onSuccess: function(){}, onFailure: function(){}}); return false;">⚙</a>
        <main>
        \(sections)
        </main>
        </body>
        </html>
        """
    }

    /// Private Browsing's start page (browser-12m.1): deliberately never
    /// touches ProfileManager/ProfileDataStoreManager -- there is no real
    /// profile behind a private tab to look Favorites/Frequently Visited up
    /// for, and doing so risks accidentally rendering (or, worse, writing
    /// back to) a real profile's data. Shows a plain "browsing privately"
    /// notice instead, matching the convention every mainstream browser's
    /// incognito new-tab page already uses.
    private static func renderPrivateHTML() -> String {
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(tabTitle))</title>
        <style>\(css(background: "background: \(gradientCSS(from: "#3a3a3c"));"))</style>
        </head>
        <body>
        <main>
        <p class="empty">You're browsing privately.<br>History, downloads, and site data from this window won't be saved.</p>
        </main>
        </body>
        </html>
        """
    }

    private static func section(title: String, tiles: [StartPageTile], profileId: String) -> String {
        let tileHTML = tiles.map { tile -> String in
            return """
            <a class="tile" href="\(escape(tile.url))">
              \(thumb(for: tile, profileId: profileId))
              <span class="tile-title">\(escape(tile.title))</span>
            </a>
            """
        }.joined()

        return """
        <section>
        <h2>\(escape(title))</h2>
        <div class="grid">\(tileHTML)</div>
        </section>
        """
    }

    /// A tile's 56x56 icon well: the site's cached favicon when there is one,
    /// otherwise the monogram. Both shapes carry the same box metrics so a
    /// mixed grid stays on one baseline.
    private static func thumb(for tile: StartPageTile, profileId: String) -> String {
        if let host = URL(string: tile.url)?.host, !host.isEmpty,
           let data = FaviconLoader.shared.cachedFaviconData(host: host, profileId: profileId) {
            let base64 = data.base64EncodedString()
            return "<span class=\"thumb\"><img class=\"icon\" src=\"data:image/png;base64,\(base64)\" alt=\"\"></span>"
        }
        let monogramSource = tile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let monogram = monogramSource.isEmpty ? "?" : String(monogramSource.prefix(1)).uppercased()
        return "<span class=\"thumb monogram\">\(escape(monogram))</span>"
    }

    /// A section header with an actionable message instead of a tile grid
    /// (browser-5kq.7) -- see renderHTML's own comment for why this exists
    /// instead of just omitting the section.
    private static func emptySection(title: String, message: String) -> String {
        return """
        <section>
        <h2>\(escape(title))</h2>
        <p class="empty-inline">\(escape(message))</p>
        </section>
        """
    }

    private static func gradientCSS(from hex: String) -> String {
        "linear-gradient(135deg, \(hex) 0%, #ffffff 140%)"
    }

    /// The `body` background declarations: the chosen picture when this
    /// profile has one (browser-1wo), otherwise the two-tone color gradient.
    ///
    /// The image is inlined as a `data:` URI because this page is one itself
    /// -- see StartPageBackgroundImageStore -- and is fixed rather than
    /// scrolling, so it reads as a backdrop behind the tiles rather than a
    /// picture the content slides over. The white scrim layered on top is what
    /// keeps this page's dark text and translucent tile wells legible over an
    /// arbitrary photograph, which no fixed text color could do on its own.
    private static func backgroundCSS(for settings: StartPageSettings, profileId: String) -> String {
        let gradient = gradientCSS(from: settings.backgroundColorHex)
        // A recorded image whose file has since gone missing falls back to the
        // color rather than rendering an empty page.
        guard settings.backgroundImageFileName != nil,
              let imageURI = StartPageBackgroundImageStore.dataURI(forProfileId: profileId) else {
            return "background: \(gradient);"
        }
        return """
        background-color: \(settings.backgroundColorHex);
          background-image:
            linear-gradient(180deg, rgba(255, 255, 255, 0.45) 0%, rgba(255, 255, 255, 0.22) 100%),
            url("\(imageURI)");
          background-size: cover;
          background-position: center;
          background-repeat: no-repeat;
          background-attachment: fixed;
        """
    }

    private static func css(background: String) -> String {
        """
        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100vh;
          \(background)
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          color: #1c1c1e;
        }
        .gear {
          position: fixed;
          top: 16px;
          right: 16px;
          width: 32px;
          height: 32px;
          display: flex;
          align-items: center;
          justify-content: center;
          border-radius: 16px;
          background: rgba(255, 255, 255, 0.6);
          text-decoration: none;
          color: #1c1c1e;
          font-size: 16px;
        }
        main {
          max-width: 720px;
          margin: 0 auto;
          padding: 96px 32px 32px;
        }
        h2 {
          font-size: 13px;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.04em;
          color: rgba(28, 28, 30, 0.6);
          margin: 0 0 12px;
        }
        section { margin-bottom: 40px; }
        .grid {
          display: flex;
          flex-wrap: wrap;
          gap: 20px;
        }
        .tile {
          width: 88px;
          display: flex;
          flex-direction: column;
          align-items: center;
          text-decoration: none;
          color: inherit;
        }
        .thumb {
          width: 56px;
          height: 56px;
          border-radius: 14px;
          background: rgba(255, 255, 255, 0.75);
          display: flex;
          align-items: center;
          justify-content: center;
          margin-bottom: 8px;
        }
        .monogram {
          font-size: 22px;
          font-weight: 600;
        }
        .icon {
          width: 32px;
          height: 32px;
          object-fit: contain;
        }
        .tile-title {
          font-size: 12px;
          text-align: center;
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
          max-width: 88px;
        }
        .empty {
          text-align: center;
          color: rgba(28, 28, 30, 0.5);
          margin-top: 64px;
        }
        .empty-inline {
          font-size: 13px;
          color: rgba(28, 28, 30, 0.5);
          margin: 0;
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
