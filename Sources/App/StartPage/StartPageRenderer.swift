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
/// Favicons are deliberately NOT fetched for tiles: FaviconLoader's fetch is
/// async and happens after render, so embedding real favicons here would
/// mean either blocking the page render on network calls or re-rendering
/// after each one arrives. Each tile instead shows a plain colored-circle
/// monogram (the title's first letter) -- the same fallback most browsers
/// already show before a real favicon has loaded.
enum StartPageRenderer {
    /// Appended (as a URL fragment) by the gear button's plain
    /// `<a href="#browser-settings">` link -- a same-document fragment
    /// click never triggers a real navigation/network request, so
    /// Tab.engineTabDidChangeURL can intercept exactly this suffix to open
    /// Settings' Start Page tab, with no JS-to-Swift bridge message channel
    /// (none exists yet) and no CEF request interception needed.
    static let settingsFragment = "#browser-settings"

    static func dataURL(profileName: String, isPrivate: Bool = false) -> String {
        let html = isPrivate ? renderPrivateHTML() : renderHTML(profileName: profileName)
        let base64 = Data(html.utf8).base64EncodedString()
        return "data:text/html;charset=utf-8;base64,\(base64)"
    }

    private struct Tile {
        let title: String
        let url: String
    }

    private static func renderHTML(profileName: String) -> String {
        let settings = StartPageSettingsStore.load(forProfileName: profileName)
        let (favorites, frequentlyVisited) = tileData(profileName: profileName, settings: settings)

        var sections = ""
        if settings.showFavorites, !favorites.isEmpty {
            sections += section(title: "Favorites", tiles: favorites)
        }
        if settings.showFrequentlyVisited, !frequentlyVisited.isEmpty {
            sections += section(title: "Frequently Visited", tiles: frequentlyVisited)
        }
        if sections.isEmpty {
            sections = "<p class=\"empty\">Nothing to show yet — browse a bit, or add a favorite.</p>"
        }

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>\(css(gradient: gradientCSS(from: settings.backgroundColorHex)))</style>
        </head>
        <body>
        <a class="gear" href="\(settingsFragment)" title="Start page settings">⚙</a>
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
        <style>\(css(gradient: gradientCSS(from: "#3a3a3c")))</style>
        </head>
        <body>
        <main>
        <p class="empty">You're browsing privately.<br>History, downloads, and site data from this window won't be saved.</p>
        </main>
        </body>
        </html>
        """
    }

    private static func tileData(profileName: String, settings: StartPageSettings) -> (favorites: [Tile], frequentlyVisited: [Tile]) {
        guard let profile = ProfileManager.shared.profile(named: profileName) else { return ([], []) }
        let stores = ProfileDataStoreManager.shared.stores(for: profile)

        var favorites: [Tile] = []
        if settings.showFavorites, let folderId = FavoritesFolder.id(in: stores.bookmarks) {
            let items = (try? stores.bookmarks.children(of: folderId)) ?? []
            favorites = items.compactMap { item in
                guard item.kind == .bookmark, let url = item.url else { return nil }
                return Tile(title: item.title.isEmpty ? url : item.title, url: url)
            }
        }

        var frequentlyVisited: [Tile] = []
        if settings.showFrequentlyVisited {
            let entries = (try? stores.history.topFrecent(limit: 8)) ?? []
            frequentlyVisited = entries.map { Tile(title: $0.title.isEmpty ? $0.url : $0.title, url: $0.url) }
        }

        return (favorites, frequentlyVisited)
    }

    private static func section(title: String, tiles: [Tile]) -> String {
        let tileHTML = tiles.map { tile -> String in
            let monogramSource = tile.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let monogram = monogramSource.isEmpty ? "?" : String(monogramSource.prefix(1)).uppercased()
            return """
            <a class="tile" href="\(escape(tile.url))">
              <span class="monogram">\(escape(monogram))</span>
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

    private static func gradientCSS(from hex: String) -> String {
        "linear-gradient(135deg, \(hex) 0%, #ffffff 140%)"
    }

    private static func css(gradient: String) -> String {
        """
        * { box-sizing: border-box; }
        body {
          margin: 0;
          min-height: 100vh;
          background: \(gradient);
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
        .monogram {
          width: 56px;
          height: 56px;
          border-radius: 14px;
          background: rgba(255, 255, 255, 0.75);
          display: flex;
          align-items: center;
          justify-content: center;
          font-size: 22px;
          font-weight: 600;
          margin-bottom: 8px;
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
