import Foundation

/// `browser route-test <url> [--from-app <bundle-id>]` -- pure RoutingCore,
/// no running app needed (reads routing.json/profiles.json directly). Great
/// for debugging a rule that silently isn't matching, since it reports
/// exactly which rule (if any) matched and what it matched on.
public enum RouteTestCommand {
    public static func run(args: ParsedArgs) -> Bool {
        guard let url = args.positionals.first else {
            return Output.emitError("usage: browser route-test <url> [--from-app <bundle-id>]", json: args.jsonOutput)
        }
        let fromApp = args.flags["from-app"]

        let directory = DiskLocations.sessionAndProfilesMetadataDirectory(arguments: CommandLine.arguments)
        let profiles = ProfileRecordStore.load(directory: directory)
        let configuration = RoutingConfigurationStore.load(directory: directory, profiles: profiles)

        do {
            let result = try RouteTestEngine.run(url: url, fromApp: fromApp, configuration: configuration, profiles: profiles)
            return Output.emit(result, json: args.jsonOutput) { output in
                let ruleNote = output.matchedRuleIndex.map { "rule #\($0) (\(output.matchedRuleSummary ?? ""))" } ?? "no rule matched -- default profile"
                return "\(output.url) -> profile '\(output.profileName)' [\(ruleNote)]"
            }
        } catch {
            return Output.emitError("\(error)", json: args.jsonOutput)
        }
    }
}
