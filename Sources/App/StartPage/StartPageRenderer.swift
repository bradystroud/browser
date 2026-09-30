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
///
/// Visual design: everything sits inside one frosted panel rather than
/// floating loose on the backdrop. That is a legibility decision before it
/// is an aesthetic one -- see `css(background:)` for how an arbitrary
/// user photograph is made safe to put text on.
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

    /// The part of a start-page data: URL that identifies it, independent of
    /// how an engine re-reports it: the media-type parameters and percent-
    /// encoding of the payload can both differ from what dataURL produced.
    /// Nil for anything that is not a data: URL.
    /// True for a data: URL that holds a start page this app rendered,
    /// including one saved in an older session. A session saved while the
    /// start page's URL leaked into Tab.urlString stores the raw data: URL;
    /// restoring it must re-render the start page, not show that URL as an
    /// ordinary page. Every normal-window start page carries the gear
    /// button's openStartPageSettings message, so that is the marker.
    static func isStartPageDataURL(_ url: String) -> Bool {
        guard url.lowercased().hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return false }
        let header = url[..<comma].lowercased()
        guard header.hasPrefix("data:text/html") else { return false }
        let payload = String(url[url.index(after: comma)...])
        let decoded: String?
        if header.hasSuffix(";base64") {
            let base64 = payload.removingPercentEncoding ?? payload
            decoded = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
        } else {
            decoded = payload.removingPercentEncoding
        }
        return decoded?.contains("'openStartPageSettings'") ?? false
    }

    static func payloadKey(_ url: String) -> String? {
        guard url.lowercased().hasPrefix("data:"), let comma = url.firstIndex(of: ",") else { return nil }
        let payload = String(url[url.index(after: comma)...])
        return payload.removingPercentEncoding ?? payload
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
                : section(built, profileId: profileId)
        }
        if settings.showBookmarks {
            let groups = StartPageSections.bookmarkGroups(profileId: profileId)
            sections += groups.isEmpty
                ? emptySection(title: StartPageSections.bookmarksTitle, message: StartPageSections.bookmarksEmptyMessage)
                : bookmarksSection(groups, profileId: profileId)
        }
        // Every section turned off in Settings -- the one case no
        // per-section empty state above ever fires for. The panel narrows to
        // suit one sentence instead of stretching a full-width bar around it.
        let isBare = sections.isEmpty
        if isBare {
            sections = "<p class=\"empty\">Nothing to show yet — browse a bit, or add a favorite.</p>"
        }

        let hasImage = settings.backgroundImageFileName != nil
            && StartPageBackgroundImageStore.dataURI(forProfileId: profileId) != nil

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escape(tabTitle))</title>
        <style>\(css(background: backgroundCSS(for: settings, profileId: profileId)))</style>
        </head>
        <body class="\(hasImage ? "photo" : "")">
        <main>
        <div class="panel glass\(isBare ? " narrow" : "")">
        <a class="gear" href="#" title="Start page settings" aria-label="Start page settings" onclick="window.cefQuery({request: JSON.stringify({type: 'openStartPageSettings'}), onSuccess: function(){}, onFailure: function(){}}); return false;">\(gearGlyph)</a>
        \(sections)
        </div>
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
        <style>\(css(background: gradientBackgroundCSS(seedHex: "#3a3a3c")))</style>
        </head>
        <body>
        <main>
        <div class="panel glass narrow">
        <p class="empty">\(privateMark)You're browsing privately.<br><span class="empty-sub">History, downloads, and site data from this window won't be saved.</span></p>
        </div>
        </main>
        </body>
        </html>
        """
    }

    /// Drawn to match SF Symbols' `gearshape`, so it reads as the same icon
    /// family as the native toolbar. A typed U+2699 comes from whatever text
    /// font has it and never matches. `currentColor` keeps `.gear`'s color
    /// and hover styles in charge.
    private static let gearGlyph = """
    <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" \
    stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">\
    <path d="M10.08 4.85L10.42 2.53A9.6 9.6 0 0 1 13.58 2.53\
    L13.92 4.85A7.4 7.4 0 0 1 15.7 5.59L17.57 4.18A9.6 9.6 0 0 1 19.82 6.43\
    L18.41 8.3A7.4 7.4 0 0 1 19.15 10.08L21.47 10.42A9.6 9.6 0 0 1 21.47 13.58\
    L19.15 13.92A7.4 7.4 0 0 1 18.41 15.7L19.82 17.57A9.6 9.6 0 0 1 17.57 19.82\
    L15.7 18.41A7.4 7.4 0 0 1 13.92 19.15L13.58 21.47A9.6 9.6 0 0 1 10.42 21.47\
    L10.08 19.15A7.4 7.4 0 0 1 8.3 18.41L6.43 19.82A9.6 9.6 0 0 1 4.18 17.57\
    L5.59 15.7A7.4 7.4 0 0 1 4.85 13.92L2.53 13.58A9.6 9.6 0 0 1 2.53 10.42\
    L4.85 10.08A7.4 7.4 0 0 1 5.59 8.3L4.18 6.43A9.6 9.6 0 0 1 6.43 4.18\
    L8.3 5.59A7.4 7.4 0 0 1 10.08 4.85Z"/>\
    <circle cx="12" cy="12" r="3"/></svg>
    """

    /// The Private Browsing notice's mark, drawn rather than typed. The
    /// obvious emoji for it (U+1F576) has no usable text presentation --
    /// forced monochrome it renders as an unreadable dark blob at any size
    /// this page would use it. Inline SVG on `currentColor` is crisp, takes
    /// the appearance's own ink color, and depends on no emoji font.
    private static let privateMark = """
    <svg class="empty-mark" viewBox="0 0 24 24" width="28" height="28" fill="none" \
    stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" \
    aria-hidden="true"><path d="M3 3l18 18"/>\
    <path d="M10.6 5.2A9.6 9.6 0 0 1 12 5.1c5 0 9 4.4 9 6.9 0 .9-.5 2-1.4 3.1"/>\
    <path d="M6.2 7A8.4 8.4 0 0 0 3 12c0 2.5 4 6.9 9 6.9 1.6 0 3.1-.4 4.4-1.2"/>\
    <path d="M9.9 9.9a3 3 0 0 0 4.2 4.2"/></svg>
    """

    /// Bookmarks become an icon grid, history a compact two-column row list.
    /// Two shapes rather than one repeated twice: it gives the page a visual
    /// hierarchy (the pinned things read as bigger targets than the merely
    /// frequent ones) and lets the history rows carry their host, which does
    /// not fit under a 46px tile.
    private static func section(_ built: StartPageSection, profileId: String) -> String {
        let body: String
        switch built.kind {
        case .bookmarks:
            let tiles = built.tiles.map { tile in
                """
                <a class="tile" href="\(escape(tile.url))" title="\(escape(tile.url))">
                  \(well(for: tile, profileId: profileId))
                  <span class="label">\(escape(tile.title))</span>
                </a>
                """
            }.joined()
            body = "<div class=\"grid\">\(tiles)</div>"
        case .history:
            let rows = built.tiles.map { tile -> String in
                let host = displayHost(of: tile.url)
                let hostSpan = host.isEmpty ? "" : "<span class=\"row-host\">\(escape(host))</span>"
                return """
                <a class="row" href="\(escape(tile.url))" title="\(escape(tile.url))">
                  \(well(for: tile, profileId: profileId))
                  <span class="row-line"><span class="row-title">\(escape(tile.title))</span>\(hostSpan)</span>
                </a>
                """
            }.joined()
            body = "<div class=\"rows\">\(rows)</div>"
        }

        return """
        <section class="sec">
        <h2>\(escape(built.title))</h2>
        \(body)
        </section>
        """
    }

    /// Favicon bytes (base64) the Bookmarks section may embed. The whole page
    /// is a `data:` URL capped at 2 MiB, and a background picture can already
    /// use most of that (see StartPageBackgroundImageStore.maxEncodedBytes), so
    /// a large bookmark collection can't embed every icon. Past the budget,
    /// rows fall back to a monogram.
    private static let bookmarkFaviconBudget = 100_000

    /// Loose top-level bookmarks first, then one collapsible group per
    /// folder, closed by default so a big collection doesn't push the rest of
    /// the page away.
    private static func bookmarksSection(_ groups: [StartPageSections.BookmarkGroup], profileId: String) -> String {
        var budget = bookmarkFaviconBudget
        func rows(_ tiles: [StartPageTile]) -> String {
            let body = tiles.map { tile -> String in
                let host = displayHost(of: tile.url)
                let hostSpan = host.isEmpty ? "" : "<span class=\"row-host\">\(escape(host))</span>"
                return """
                <a class="row" href="\(escape(tile.url))" title="\(escape(tile.url))">
                  \(well(for: tile, profileId: profileId, faviconBudget: &budget))
                  <span class="row-line"><span class="row-title">\(escape(tile.title))</span>\(hostSpan)</span>
                </a>
                """
            }.joined()
            return "<div class=\"rows\">\(body)</div>"
        }

        let body = groups.map { group -> String in
            guard let title = group.title else { return rows(group.tiles) }
            return """
            <details class="folder">
            <summary>\(escape(title))<span class="count">\(group.tiles.count)</span></summary>
            \(rows(group.tiles))
            </details>
            """
        }.joined()

        return """
        <section class="sec">
        <h2>\(escape(StartPageSections.bookmarksTitle))</h2>
        \(body)
        </section>
        """
    }

    /// A tile's icon well: the site's cached favicon when there is one,
    /// otherwise the monogram. Both shapes carry the same box metrics so a
    /// mixed grid stays on one baseline; the grid and the row list size the
    /// same markup differently in CSS.
    private static func well(for tile: StartPageTile, profileId: String) -> String {
        var unlimited = Int.max
        return well(for: tile, profileId: profileId, faviconBudget: &unlimited)
    }

    /// Embeds the favicon only while `faviconBudget` covers it, and charges
    /// the budget for it.
    private static func well(for tile: StartPageTile, profileId: String, faviconBudget: inout Int) -> String {
        if let host = URL(string: tile.url)?.host, !host.isEmpty,
           let data = FaviconLoader.shared.cachedFaviconData(host: host, profileId: profileId) {
            let base64 = data.base64EncodedString()
            if base64.count <= faviconBudget {
                faviconBudget -= base64.count
                return "<span class=\"well\"><img src=\"data:image/png;base64,\(base64)\" alt=\"\"></span>"
            }
        }
        let monogramSource = tile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let monogram = monogramSource.isEmpty ? "?" : String(monogramSource.prefix(1)).uppercased()
        return "<span class=\"well\"><span class=\"mono\">\(escape(monogram))</span></span>"
    }

    /// The bare host for a history row's trailing label. `www.` is dropped
    /// because it is never the part that identifies the site, and an empty
    /// result (a URL with no host at all) makes the caller omit the label
    /// rather than render a stray separator.
    private static func displayHost(of url: String) -> String {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A section header with an actionable message instead of a tile grid
    /// (browser-5kq.7) -- see renderHTML's own comment for why this exists
    /// instead of just omitting the section. The dashed placeholder next to
    /// the message keeps the section roughly the shape it will have once it
    /// has content, so an empty start page still reads as a layout rather
    /// than as a line of grey text.
    private static func emptySection(title: String, message: String) -> String {
        return """
        <section class="sec">
        <h2>\(escape(title))</h2>
        <p class="empty-inline">\(escape(message))</p>
        </section>
        """
    }

    /// The `body` background declarations: the chosen picture when this
    /// profile has one (browser-1wo), otherwise the two-tone color gradient.
    ///
    /// The image is inlined as a `data:` URI because this page is one itself
    /// -- see StartPageBackgroundImageStore -- and is fixed rather than
    /// scrolling, so it reads as a backdrop behind the panel rather than a
    /// picture the content slides over.
    private static func backgroundCSS(for settings: StartPageSettings, profileId: String) -> String {
        // A recorded image whose file has since gone missing falls back to the
        // color rather than rendering an empty page.
        guard settings.backgroundImageFileName != nil,
              let imageURI = StartPageBackgroundImageStore.dataURI(forProfileId: profileId) else {
            return gradientBackgroundCSS(seedHex: settings.backgroundColorHex)
        }
        return """
        :root { --seed: \(settings.backgroundColorHex); }
        body {
          background-color: var(--seed);
          background-image: url("\(imageURI)");
          background-size: cover;
          background-position: center;
          background-repeat: no-repeat;
          background-attachment: fixed;
        }
        """
    }

    /// The no-picture backdrop: the profile's own accent color falling away
    /// into the page tint, plus a soft off-canvas highlight so it reads as a
    /// lit surface rather than a flat ramp.
    ///
    /// `color-mix` is what carries the user's chosen hue into dark mode. The
    /// stored color is picked against a light page and is far too bright to
    /// sit behind white text, so dark mode blends it down toward near-black
    /// instead of substituting some unrelated dark color -- the profile stays
    /// recognisable in both appearances from one stored value.
    private static func gradientBackgroundCSS(seedHex: String) -> String {
        """
        :root { --seed: \(seedHex); --seed-eff: var(--seed); }
        @media (prefers-color-scheme: dark) {
          :root { --seed-eff: color-mix(in oklab, var(--seed) 46%, #07080b); }
        }
        body {
          background-color: var(--tint-b);
          background-image:
            radial-gradient(1100px 620px at 18% -12%, var(--tint-a) 0%, rgba(0, 0, 0, 0) 62%),
            linear-gradient(152deg, var(--seed-eff) 0%, var(--tint-b) 118%);
          background-attachment: fixed;
        }
        """
    }

    /// The whole stylesheet, pasted into every new tab -- kept to a few
    /// kilobytes, which is nothing next to an inlined background photograph.
    ///
    /// How arbitrary photographs are made safe to put text on, since this is
    /// the part that is easy to break: the page never relies on the backdrop
    /// being any particular brightness. All content sits on one surface this
    /// page owns, and `--glass` conditions whatever is behind that surface
    /// before it shows through. `contrast(0.5)` collapses the backdrop's
    /// whole tonal range toward mid-grey and `brightness()` then pushes that
    /// compressed range to the end the current appearance needs -- up in
    /// light, down in dark. A pure-black wallpaper and a pure-white one
    /// therefore arrive at the panel within a few percent of each other, so
    /// one fixed ink color stays legible over both. Verified against a
    /// hard-edged black/white split, a dense high-contrast photo, an almost
    /// entirely white one and an almost entirely black one.
    ///
    /// The translucency is an enhancement and never the thing legibility
    /// rests on: `--surface` is opaque enough on its own, and only drops to a
    /// glassy alpha inside the `@supports` block that proves the conditioning
    /// filter is actually available.
    private static func css(background: String) -> String {
        """
        :root {
          color-scheme: light dark;
          --ink: #14161b;
          --ink-2: rgba(24, 28, 36, 0.62);
          --ink-3: rgba(24, 28, 36, 0.45);
          --surface: rgba(255, 255, 255, 0.94);
          --surface-edge: rgba(255, 255, 255, 0.72);
          --surface-ring: rgba(14, 16, 22, 0.07);
          --hover: rgba(14, 16, 22, 0.055);
          --active: rgba(14, 16, 22, 0.09);
          --well: #fbfcfe;
          --well-ring: rgba(14, 16, 22, 0.10);
          --mono-ink: #3c414c;
          --rule: rgba(14, 16, 22, 0.09);
          --shadow: 0 28px 70px rgba(10, 12, 18, 0.22), 0 2px 10px rgba(10, 12, 18, 0.07);
          --veil: linear-gradient(180deg, rgba(255, 255, 255, 0.26) 0%, rgba(255, 255, 255, 0.08) 100%);
          --focus: #0a63d2;
          --glass: blur(40px) saturate(160%) contrast(0.5) brightness(1.9);
          --tint-a: rgba(255, 255, 255, 0.55);
          --tint-b: #fdfdff;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --ink: #f2f4f8;
            --ink-2: rgba(234, 239, 248, 0.62);
            --ink-3: rgba(234, 239, 248, 0.44);
            --surface: rgba(24, 26, 32, 0.93);
            --surface-edge: rgba(255, 255, 255, 0.13);
            --surface-ring: rgba(0, 0, 0, 0.45);
            --hover: rgba(255, 255, 255, 0.09);
            --active: rgba(255, 255, 255, 0.15);
            /* The icon well stays light in dark mode on purpose: a great many
               real favicons are dark ink on a transparent background and
               vanish against a dark well. A white logo on transparent is far
               rarer -- one would already be invisible on Chrome's and
               Safari's light new-tab pages, so almost nobody ships one. */
            --well: rgba(243, 246, 251, 0.94);
            --well-ring: rgba(0, 0, 0, 0.3);
            --mono-ink: #3c414c;
            --rule: rgba(255, 255, 255, 0.10);
            --shadow: 0 28px 70px rgba(0, 0, 0, 0.5), 0 2px 10px rgba(0, 0, 0, 0.3);
            --veil: linear-gradient(180deg, rgba(5, 7, 11, 0.34) 0%, rgba(5, 7, 11, 0.12) 100%);
            --focus: #6aa5ff;
            --glass: blur(40px) saturate(160%) contrast(0.5) brightness(0.4);
            --tint-a: rgba(255, 255, 255, 0.10);
            --tint-b: #08090c;
          }
        }
        @supports (backdrop-filter: blur(2px)) or (-webkit-backdrop-filter: blur(2px)) {
          :root { --surface: rgba(255, 255, 255, 0.66); }
          @media (prefers-color-scheme: dark) { :root { --surface: rgba(22, 24, 30, 0.66); } }
          .glass { -webkit-backdrop-filter: var(--glass); backdrop-filter: var(--glass); }
        }
        @media (prefers-reduced-transparency: reduce) {
          :root { --surface: #f4f5f8; --veil: none; }
          @media (prefers-color-scheme: dark) { :root { --surface: #1a1c22; } }
          .glass { -webkit-backdrop-filter: none !important; backdrop-filter: none !important; }
        }
        @media (prefers-reduced-motion: reduce) {
          * { transition: none !important; animation: none !important; }
        }
        * { box-sizing: border-box; }
        html { height: 100%; }
        body {
          margin: 0;
          min-height: 100vh;
          color: var(--ink);
          font: 400 14px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
          -webkit-font-smoothing: antialiased;
        }
        \(background)
        body.photo::before {
          content: "";
          position: fixed;
          inset: 0;
          background: var(--veil);
          pointer-events: none;
        }
        a { -webkit-tap-highlight-color: transparent; }
        a:focus-visible { outline: 2px solid var(--focus); outline-offset: 3px; }
        main { max-width: 800px; margin: 0 auto; padding: 11vh 28px 56px; }
        @media (max-height: 680px) { main { padding-top: 6vh; } }
        .panel {
          position: relative;
          border-radius: 26px;
          background: var(--surface);
          box-shadow: 0 0 0 1px var(--surface-ring), inset 0 1px 0 var(--surface-edge), var(--shadow);
          padding: 24px 22px 10px;
        }
        .panel.narrow { max-width: 460px; margin: 0 auto; padding: 10px 22px; }
        .gear {
          position: absolute;
          top: 16px;
          right: 16px;
          width: 30px;
          height: 30px;
          border-radius: 50%;
          display: flex;
          align-items: center;
          justify-content: center;
          color: var(--ink-2);
          text-decoration: none;
          font-size: 16px;
          line-height: 1;
          transition: background 0.15s ease, color 0.15s ease;
        }
        .gear:hover { background: var(--hover); color: var(--ink); }
        .sec { padding: 4px 4px 16px; }
        .sec + .sec { border-top: 1px solid var(--rule); padding-top: 18px; }
        h2 {
          margin: 0 0 12px 8px;
          font-size: 11px;
          font-weight: 590;
          letter-spacing: 0.07em;
          text-transform: uppercase;
          color: var(--ink-2);
        }
        .well {
          flex: 0 0 auto;
          display: flex;
          align-items: center;
          justify-content: center;
          background: var(--well);
          box-shadow: 0 1px 2px rgba(10, 12, 18, 0.16), 0 0 0 1px var(--well-ring),
            inset 0 0 0 1px rgba(14, 16, 22, 0.05);
          overflow: hidden;
        }
        .well img { object-fit: contain; }
        .mono { font-weight: 600; color: var(--mono-ink); letter-spacing: -0.01em; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(88px, 1fr)); gap: 2px; }
        .tile {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 9px;
          padding: 12px 6px;
          border-radius: 16px;
          text-decoration: none;
          color: inherit;
          transition: background 0.15s ease, transform 0.15s ease;
        }
        .tile:hover { background: var(--hover); }
        .tile:active { background: var(--active); transform: scale(0.97); }
        .tile .well { width: 46px; height: 46px; border-radius: 12px; }
        .tile .well img { width: 26px; height: 26px; }
        .tile .mono { font-size: 19px; }
        .label {
          font-size: 11.5px;
          line-height: 1.32;
          text-align: center;
          /* Two fixed lines, so a one-word title and a long one leave the
             grid on the same baseline instead of stepping up and down. */
          height: 2.64em;
          overflow: hidden;
          display: -webkit-box;
          -webkit-line-clamp: 2;
          -webkit-box-orient: vertical;
          word-break: break-word;
        }
        .rows { display: grid; grid-template-columns: repeat(auto-fill, minmax(330px, 1fr)); gap: 1px 8px; }
        .row {
          display: flex;
          align-items: center;
          gap: 10px;
          padding: 8px 10px;
          border-radius: 11px;
          text-decoration: none;
          color: inherit;
          transition: background 0.15s ease;
        }
        .row:hover { background: var(--hover); }
        .row .well { width: 26px; height: 26px; border-radius: 8px; }
        .row .well img { width: 16px; height: 16px; }
        .row .mono { font-size: 12px; }
        /* Title and host share one truncating line, so a tight column drops
           the host rather than making the two compete for the same ellipsis. */
        .row-line { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .row-title { font-size: 13px; }
        .row-host { font-size: 11.5px; color: var(--ink-3); margin-left: 7px; }
        .folder { margin: 2px 0; }
        .folder summary {
          display: flex;
          align-items: center;
          gap: 8px;
          padding: 8px 10px;
          border-radius: 11px;
          font-size: 13px;
          font-weight: 590;
          cursor: default;
          list-style: none;
        }
        .folder summary::-webkit-details-marker { display: none; }
        .folder summary::before {
          content: "";
          width: 6px;
          height: 6px;
          border-right: 1.5px solid var(--ink-2);
          border-bottom: 1.5px solid var(--ink-2);
          transform: rotate(-45deg);
          transition: transform 0.15s ease;
          margin: 0 4px 0 2px;
        }
        .folder[open] summary::before { transform: rotate(45deg); }
        .folder summary:hover { background: var(--hover); }
        .folder .count { font-size: 11.5px; font-weight: 400; color: var(--ink-3); }
        .folder .rows { padding-left: 18px; }
        .empty-inline {
          display: flex;
          align-items: center;
          gap: 12px;
          margin: 0 0 4px 6px;
          padding: 8px 6px 14px;
          font-size: 13px;
          color: var(--ink-2);
        }
        .empty-inline::before {
          content: "";
          flex: 0 0 auto;
          width: 46px;
          height: 46px;
          border-radius: 12px;
          border: 1.5px dashed var(--rule);
        }
        .empty {
          margin: 0;
          /* Wide side padding keeps a centred sentence clear of the gear,
             which is absolutely positioned in the same top-right corner. */
          padding: 30px 44px 34px;
          text-align: center;
          font-size: 14px;
          line-height: 1.55;
          color: var(--ink);
        }
        .empty-mark { display: block; margin: 0 auto 16px; color: var(--ink-3); }
        .empty-sub { color: var(--ink-2); font-size: 13px; }
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
