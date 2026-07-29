import Foundation
import BrowserCore

/// One bookmark or folder for CLI output -- mirrors `BrowserCore.BookmarkItem`
/// minus its internal `parentId`/`position`/`createdAt`, which don't mean
/// anything outside the store itself.
public struct BookmarkItemRecord: Codable {
    public let id: Int64
    public let kind: String
    public let title: String
    public let url: String?

    init(_ item: BookmarkItem) {
        id = item.id
        kind = item.kind.rawValue
        title = item.title
        url = item.url
    }
}

public struct BookmarksListResult: Codable {
    public let profile: String
    public let folder: String
    public let items: [BookmarkItemRecord]
}

/// `browser bookmarks list [--folder <path>] [--profile <name>]` -- works
/// without the app running, same reasoning as `history search`. `--folder`
/// is a `/`-separated path of folder titles (case-insensitive), e.g.
/// `"Favourites/Work"`; omitted means the top level.
public enum BookmarksCommand {
    public static func list(args: ParsedArgs) -> Bool {
        let folderPath = args.flags["folder"] ?? ""

        let directory = DiskLocations.sessionAndProfilesMetadataDirectory(arguments: CommandLine.arguments)
        let profilesRoot = DiskLocations.profilesRootPath(arguments: CommandLine.arguments)

        do {
            let (profile, database) = try ProfileDatabaseResolver.resolve(
                profileNameFlag: args.flags["profile"], directory: directory, profilesRootPath: profilesRoot)
            let store = BookmarkStore(database: database)
            let parentId = try resolveFolder(path: folderPath, store: store)
            let items = try store.children(of: parentId).map(BookmarkItemRecord.init)
            let result = BookmarksListResult(profile: profile.name, folder: folderPath.isEmpty ? "/" : folderPath, items: items)
            return Output.emit(result, json: args.jsonOutput) { result in
                guard !result.items.isEmpty else { return "(empty folder '\(result.folder)' in profile '\(result.profile)')" }
                return result.items.map { item in
                    item.kind == "folder" ? "[folder]\t\(item.title)" : "\t\(item.title)\t\(item.url ?? "")"
                }.joined(separator: "\n")
            }
        } catch {
            return Output.emitError("\(error)", json: args.jsonOutput)
        }
    }

    /// Walks `path` (`/`-separated folder titles) from the top level,
    /// matching each component against that level's folder-kind children
    /// case-insensitively. An empty path resolves to the top level itself
    /// (`nil` parentId).
    static func resolveFolder(path: String, store: BookmarkStore) throws -> Int64? {
        let components = path.split(separator: "/").map(String.init)
        var currentParent: Int64?
        for component in components {
            let children = try store.children(of: currentParent)
            guard let match = children.first(where: { $0.kind == .folder && $0.title.caseInsensitiveCompare(component) == .orderedSame }) else {
                throw SimpleError("no folder named '\(component)' under '\(path)'")
            }
            currentParent = match.id
        }
        return currentParent
    }
}
