import Foundation
import RoutingCore

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

        // Matches what a real routed link goes through before RuleMatcher
        // ever sees it (see RoutingCoordinator.route) -- otherwise a rule
        // written against a bare URL could report "no match" here while a
        // real click on a tracking-param-decorated link matches fine, the
        // exact kind of CLI/real-behavior disagreement worth avoiding.
        // Un-shortening is deliberately not replicated (see
        // LinkHandlingPreferencesReader's own doc comment).
        let effectiveURL = LinkHandlingPreferencesReader.stripTrackingParams(arguments: CommandLine.arguments)
            ? TrackingParamStripper.strip(url)
            : url

        do {
            let result = try RouteTestEngine.run(url: url, effectiveURL: effectiveURL, fromApp: fromApp, configuration: configuration, profiles: profiles)
            return Output.emit(result, json: args.jsonOutput) { output in
                let ruleNote = output.matchedRuleIndex.map { "rule #\($0) (\(output.matchedRuleSummary ?? ""))" } ?? "no rule matched -- the frontmost window, or this profile if no window is open"
                let strippedNote = output.effectiveURL == output.url ? "" : " [tracking params stripped -> \(output.effectiveURL)]"
                return "\(output.url) -> profile '\(output.profileName)' [\(ruleNote)]\(strippedNote)"
            }
        } catch {
            return Output.emitError("\(error)", json: args.jsonOutput)
        }
    }
}
