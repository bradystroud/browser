import Foundation
import BrowserCore

/// One history row for CLI output -- deliberately just url/title/visitCount/
/// lastVisitTime, mirroring `BrowserCore.HistoryEntry` exactly. Never a
/// credential (history has none to begin with; noted here anyway as the
/// same explicit guard every other output type in this CLI carries).
public struct HistoryEntryRecord: Codable {
    public let url: String
    public let title: String
    public let visitCount: Int
    public let lastVisitTime: String

    init(_ entry: HistoryEntry) {
        url = entry.url
        title = entry.title
        visitCount = entry.visitCount
        lastVisitTime = ISO8601DateFormatter().string(from: entry.lastVisitTime)
    }
}

public struct HistorySearchResult: Codable {
    public let query: String
    public let profile: String
    public let entries: [HistoryEntryRecord]
}

/// `browser history search <query> [--limit N] [--profile <name>]` --
/// works without the app running: a direct, read-only-in-practice SQLite
/// open of that profile's real `browser.db` (see ProfileDatabaseResolver).
public enum HistoryCommand {
    public static func search(args: ParsedArgs) -> Bool {
        guard let query = args.positionals.first, !query.isEmpty else {
            return Output.emitError("usage: browser history search <query> [--limit N] [--profile <name>]", json: args.jsonOutput)
        }
        let limit = args.flags["limit"].flatMap(Int.init) ?? 20

        let directory = DiskLocations.sessionAndProfilesMetadataDirectory(arguments: CommandLine.arguments)
        let profilesRoot = DiskLocations.profilesRootPath(arguments: CommandLine.arguments)

        do {
            let (profile, database) = try ProfileDatabaseResolver.resolve(
                profileNameFlag: args.flags["profile"], directory: directory, profilesRootPath: profilesRoot)
            let store = HistoryStore(database: database)
            let entries = try store.entries(matching: query, limit: limit).map(HistoryEntryRecord.init)
            let result = HistorySearchResult(query: query, profile: profile.name, entries: entries)
            return Output.emit(result, json: args.jsonOutput) { result in
                guard !result.entries.isEmpty else { return "(no matches for '\(result.query)' in profile '\(result.profile)')" }
                return result.entries.map { "\($0.visitCount)\t\($0.lastVisitTime)\t\($0.title)\t\($0.url)" }.joined(separator: "\n")
            }
        } catch {
            return Output.emitError("\(error)", json: args.jsonOutput)
        }
    }
}
