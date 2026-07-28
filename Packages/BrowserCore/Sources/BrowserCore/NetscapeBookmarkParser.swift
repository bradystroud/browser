import Foundation

/// A parsed bookmark tree, source-agnostic -- both the Netscape HTML export
/// format (NetscapeBookmarkParser) and a direct Safari Bookmarks.plist read
/// (SafariBookmarksPlistParser) produce this same shape, so everything
/// downstream (counting for the import summary, BookmarkImporter's actual
/// writes) works identically regardless of which source was used.
public indirect enum ImportedBookmarkNode: Equatable {
    case bookmark(title: String, url: String)
    /// `isFavoritesBar` marks the browser's own favorites/toolbar folder
    /// (Safari calls it "Favorites", Chrome "Bookmarks bar", Firefox
    /// "Bookmarks Toolbar") -- BookmarkImporter merges its children
    /// directly into this app's own Favorites folder instead of recreating
    /// it as a nested folder (browser-ymx: this is what makes an imported
    /// favorite show up on the start page's Favorites section).
    case folder(title: String, isFavoritesBar: Bool, children: [ImportedBookmarkNode])

    /// Total bookmark leaves and total folders across `nodes` and all their
    /// descendants -- what the import confirmation sheet's "N bookmarks in
    /// M folders" summary is built from, computed before anything is
    /// written to a BookmarkStore.
    public static func counts(in nodes: [ImportedBookmarkNode]) -> (bookmarks: Int, folders: Int) {
        var bookmarks = 0
        var folders = 0
        for node in nodes {
            switch node {
            case .bookmark:
                bookmarks += 1
            case .folder(_, _, let children):
                folders += 1
                let nested = counts(in: children)
                bookmarks += nested.bookmarks
                folders += nested.folders
            }
        }
        return (bookmarks, folders)
    }
}

/// Parses the standard Netscape bookmark HTML export format
/// (`<!DOCTYPE NETSCAPE-Bookmark-file-1>`) -- what Safari's File > Export >
/// Bookmarks emits, and also what Chrome/Firefox/Edge emit under the same
/// shared legacy format.
///
/// Parses defensively rather than as well-formed HTML/XML: real-world
/// exports (Safari's included) routinely omit `</DT>`, and browsers vary on
/// which other closing tags they bother with. A strict parser would choke
/// on this; instead this scans for the handful of tag *starts* that
/// actually carry structural meaning (`<DT><H3...>`, `<DT><A...>`, `</DL>`)
/// via regex. The DL/H3 *nesting* skeleton is what every browser's exporter
/// reliably produces correctly even when individual closing tags elsewhere
/// are missing, which is what this leans on.
public enum NetscapeBookmarkParser {
    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"<DT>\s*<H3([^>]*)>(.*?)</H3>|<DT>\s*<A\s+([^>]*)>(.*?)</A>|(</DL>)"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let hrefRegex = try! NSRegularExpression(pattern: #"HREF\s*=\s*"([^"]*)""#, options: [.caseInsensitive])
    private static let toolbarFolderRegex = try! NSRegularExpression(
        pattern: #"PERSONAL_TOOLBAR_FOLDER\s*=\s*"true""#, options: [.caseInsensitive])

    /// Top-level nodes -- folders and/or bare bookmarks not inside any
    /// folder.
    public static func parse(_ html: String) -> [ImportedBookmarkNode] {
        // A plain reference-type accumulator, not ImportedBookmarkNode
        // itself: a folder's own node can't be built until all of its
        // children are known, which only happens once its `</DL>` (or
        // end-of-document, for a truncated/very sloppily-closed export) is
        // reached.
        final class Frame {
            let title: String
            let isFavoritesBar: Bool
            var children: [ImportedBookmarkNode] = []
            init(title: String, isFavoritesBar: Bool) {
                self.title = title
                self.isFavoritesBar = isFavoritesBar
            }
        }

        var stack = [Frame(title: "", isFavoritesBar: false)] // stack[0] is a synthetic root, never popped.
        let nsHTML = html as NSString
        let fullRange = NSRange(location: 0, length: nsHTML.length)

        tokenRegex.enumerateMatches(in: html, range: fullRange) { match, _, _ in
            guard let match else { return }

            if match.range(at: 1).location != NSNotFound {
                // <DT><H3 attrs>title</H3> -- opens a new folder frame.
                let attrs = nsHTML.substring(with: match.range(at: 1))
                let title = unescapeHTML(nsHTML.substring(with: match.range(at: 2)))
                let isFavoritesBar = hasToolbarFolderMarker(attrs) || isKnownFavoritesBarTitle(title)
                stack.append(Frame(title: title, isFavoritesBar: isFavoritesBar))
            } else if match.range(at: 3).location != NSNotFound {
                // <DT><A attrs>title</A> -- a bookmark leaf in the current (innermost open) frame.
                let attrs = nsHTML.substring(with: match.range(at: 3))
                let title = unescapeHTML(nsHTML.substring(with: match.range(at: 4)))
                guard let href = extractHREF(attrs) else { return }
                stack[stack.count - 1].children.append(.bookmark(title: title, url: href))
            } else if match.range(at: 5).location != NSNotFound {
                // </DL> -- closes the most recently opened folder frame,
                // attaching it to its parent. A stray extra </DL> beyond the
                // root is just ignored rather than crashing/underflowing.
                guard stack.count > 1 else { return }
                let closed = stack.removeLast()
                stack[stack.count - 1].children.append(
                    .folder(title: closed.title, isFavoritesBar: closed.isFavoritesBar, children: closed.children))
            }
        }

        // Any folder frames still open at end-of-document (missing closing
        // </DL>s) are flushed the same way, so nothing silently vanishes.
        while stack.count > 1 {
            let closed = stack.removeLast()
            stack[stack.count - 1].children.append(
                .folder(title: closed.title, isFavoritesBar: closed.isFavoritesBar, children: closed.children))
        }

        return stack[0].children
    }

    private static func extractHREF(_ attrs: String) -> String? {
        guard let match = hrefRegex.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) else { return nil }
        return unescapeHTML((attrs as NSString).substring(with: match.range(at: 1)))
    }

    private static func hasToolbarFolderMarker(_ attrs: String) -> Bool {
        toolbarFolderRegex.firstMatch(in: attrs, range: NSRange(attrs.startIndex..., in: attrs)) != nil
    }

    /// Safari calls its favorites-bar folder "Favorites"; Chrome calls its
    /// equivalent "Bookmarks bar"; Firefox "Bookmarks Toolbar" -- a title
    /// match is a fallback for an export that (unusually) omits the
    /// PERSONAL_TOOLBAR_FOLDER marker attribute entirely.
    static func isKnownFavoritesBarTitle(_ title: String) -> Bool {
        let lower = title.lowercased()
        return lower == "favorites" || lower == "favorites bar" || lower == "bookmarks bar" || lower == "bookmarks toolbar"
    }

    static func unescapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
