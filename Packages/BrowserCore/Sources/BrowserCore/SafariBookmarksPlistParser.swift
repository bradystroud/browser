import Foundation

/// Parses `~/Library/Safari/Bookmarks.plist` directly -- the opportunistic
/// "Import directly from Safari" path (browser-ymx), skipping the manual
/// File > Export > Bookmarks step entirely when it works. Produces the same
/// `ImportedBookmarkNode` tree as `NetscapeBookmarkParser`, so the rest of
/// the import pipeline (summary counts, BookmarkImporter) doesn't care
/// which source was used.
public enum SafariBookmarksPlistParser {
    public enum ReadError: Error {
        /// `NSDictionary(contentsOf:)` returned nil -- confirmed empirically
        /// (see docs/ai-tasks) that this is exactly what happens for a
        /// TCC/Full-Disk-Access-protected file: no exception, no crash,
        /// just nil. Deliberately not distinguished from "file doesn't
        /// exist" -- from the caller's side both need the identical
        /// "here's how to fix it" dialog (grant Full Disk Access, or use
        /// Safari's own export instead).
        case fileNotReadable
        case unexpectedFormat
    }

    public static func defaultFileURL() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Safari/Bookmarks.plist")
    }

    public static func parse(fileURL: URL) throws -> [ImportedBookmarkNode] {
        guard let root = NSDictionary(contentsOf: fileURL) as? [String: Any] else {
            throw ReadError.fileNotReadable
        }
        guard let children = root["Children"] as? [[String: Any]] else {
            throw ReadError.unexpectedFormat
        }
        return children.compactMap(node(from:))
    }

    private static func node(from dict: [String: Any]) -> ImportedBookmarkNode? {
        let type = dict["WebBookmarkType"] as? String

        if type == "WebBookmarkTypeLeaf" {
            guard let url = dict["URLString"] as? String else { return nil }
            // A leaf bookmark's display title lives under URIDictionary.title
            // in Safari's own format, not directly under "Title" -- though
            // some entries carry both; prefer URIDictionary.title when
            // present since it's the one Safari's own UI actually shows.
            let uriTitle = (dict["URIDictionary"] as? [String: Any])?["title"] as? String
            let title = uriTitle ?? (dict["Title"] as? String) ?? url
            return .bookmark(title: title, url: url)
        }

        // Anything else that carries children is treated as a folder --
        // deliberately not gated strictly on WebBookmarkType ==
        // "WebBookmarkTypeList", since that's the documented common case
        // but this format has drifted across macOS versions; a dict with a
        // Children array is unambiguously folder-shaped regardless.
        guard let rawChildren = dict["Children"] as? [[String: Any]] else { return nil }
        let title = (dict["Title"] as? String) ?? ""
        let identifier = (dict["WebBookmarkIdentifier"] as? String) ?? ""
        let isFavoritesBar = identifier.localizedCaseInsensitiveContains("BookmarksBar")
            || NetscapeBookmarkParser.isKnownFavoritesBarTitle(title)
        let children = rawChildren.compactMap(node(from:))
        return .folder(title: title, isFavoritesBar: isFavoritesBar, children: children)
    }
}
