import Foundation
import RoutingCore

/// What `route-test` reports: which profile `url` (from `fromApp`, if given)
/// would route to, and which rule -- if any -- decided it. Pure/`Codable`
/// so both the text and `--json` output paths render the same computed
/// result.
public struct RouteTestOutput: Codable, Equatable {
    /// Exactly the URL given on the command line.
    public let url: String
    /// `url` after tracking-param stripping, if that preference is on (the
    /// default) -- equal to `url` when nothing was stripped, or when the
    /// preference is off. This, not `url`, is what's actually matched
    /// against, matching what a real routed link goes through before
    /// `RuleMatcher` ever sees it (see `Sources/App/Routing/RoutingCoordinator.swift`).
    public let effectiveURL: String
    public let fromApp: String?
    /// 1-based position in the rule list, matching how the Routing Rules
    /// pane displays them to a human -- nil means no rule matched and the
    /// default profile fallback was used.
    public let matchedRuleIndex: Int?
    public let matchedRuleSummary: String?
    public let profileId: String
    public let profileName: String

    public init(url: String, effectiveURL: String, fromApp: String?, matchedRuleIndex: Int?, matchedRuleSummary: String?, profileId: String, profileName: String) {
        self.url = url
        self.effectiveURL = effectiveURL
        self.fromApp = fromApp
        self.matchedRuleIndex = matchedRuleIndex
        self.matchedRuleSummary = matchedRuleSummary
        self.profileId = profileId
        self.profileName = profileName
    }
}

public enum RouteTestError: Error, CustomStringConvertible {
    case noProfilesFound

    public var description: String {
        switch self {
        case .noProfilesFound:
            return "No profiles found -- launch the app at least once first (it creates the default profile on first launch)."
        }
    }
}

/// The actual "what would this URL route to" computation -- pulled out of
/// the `route-test` command's I/O (reading routing.json/profiles.json/the
/// tracking-param-stripping preference) so it's testable against in-memory
/// fixtures with zero filesystem access, same "pure logic, testable in
/// isolation" shape as `RuleMatcher` itself.
///
/// Built on `RuleMatcher.evaluate(context:rules:defaultProfileId:)`, the
/// shared entry point the Routing Rules pane's own "Test" affordance also
/// calls (see that function's doc comment) -- deliberately not a
/// hand-rolled re-derivation of first-match-wins here, so this command can
/// never silently disagree with the in-app diagnostic about which rule
/// matched.
public enum RouteTestEngine {
    /// `effectiveURL` is `url` with tracking-param stripping already
    /// applied by the caller (a live preference read, so not something this
    /// pure function does itself) -- pass the same value as `url` if
    /// stripping doesn't apply.
    public static func run(
        url: String,
        effectiveURL: String,
        fromApp: String?,
        configuration: RoutingConfiguration,
        profiles: [ProfileRecord]
    ) throws -> RouteTestOutput {
        guard !profiles.isEmpty else { throw RouteTestError.noProfilesFound }

        let context = RoutingContext(url: effectiveURL, sourceBundleId: fromApp)
        let evaluation = RuleMatcher.evaluate(context: context, rules: configuration.rules, defaultProfileId: configuration.defaultProfileId)
        let resolvedProfile = evaluation
            .existingProfileId(configuredDefaultId: configuration.defaultProfileId) { id in profiles.contains { $0.id == id } }
            .flatMap { id in profiles.first { $0.id == id } }
            ?? profiles.first { $0.name == "default" }
        let profileId = resolvedProfile?.id ?? evaluation.profileId
        let profileName = resolvedProfile?.name ?? "(unknown profile id \(evaluation.profileId))"

        switch evaluation {
        case .matched(let rule, _):
            return RouteTestOutput(
                url: url,
                effectiveURL: effectiveURL,
                fromApp: fromApp,
                matchedRuleIndex: configuration.rules.firstIndex(of: rule).map { $0 + 1 },
                matchedRuleSummary: summarize(rule.match),
                profileId: profileId,
                profileName: profileName
            )
        case .noMatch:
            return RouteTestOutput(
                url: url,
                effectiveURL: effectiveURL,
                fromApp: fromApp,
                matchedRuleIndex: nil,
                matchedRuleSummary: nil,
                profileId: profileId,
                profileName: profileName
            )
        }
    }

    /// A short human-readable description of whichever fields a matched
    /// rule actually set, e.g. `"domainGlob=*.ssw.com.au"` or
    /// `"urlContains=github, sourceBundleIds=[com.apple.mail]"` -- purely
    /// cosmetic (for the CLI's own text/`--json` output), never re-parsed.
    static func summarize(_ match: RoutingRule.Match) -> String {
        var parts: [String] = []
        if let value = match.urlContains { parts.append("urlContains=\(value)") }
        if let value = match.domainGlob { parts.append("domainGlob=\(value)") }
        if let value = match.urlRegex { parts.append("urlRegex=\(value)") }
        if let value = match.sourceBundleIds, !value.isEmpty { parts.append("sourceBundleIds=\(value.joined(separator: ","))") }
        return parts.isEmpty ? "(catch-all: every field empty)" : parts.joined(separator: ", ")
    }
}

public enum RoutingConfigurationStore {
    /// Reads `<directory>/routing.json` (`RoutingRulesStore`'s own file).
    /// If it doesn't exist yet, falls back to "no rules, default profile =
    /// whichever profile is named 'default'" -- the same fallback
    /// `RoutingRulesStore.init` itself uses, just without that type's own
    /// side effect of creating the profile if it's somehow also missing
    /// (this is a read-only tool; it reports what it finds, it doesn't
    /// bootstrap state).
    public static func load(directory: String, profiles: [ProfileRecord]) -> RoutingConfiguration {
        let path = (directory as NSString).appendingPathComponent("routing.json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? JSONDecoder().decode(RoutingConfiguration.self, from: data) {
            return decoded
        }
        let fallbackDefaultId = profiles.first(where: { $0.name == "default" })?.id ?? profiles.first?.id ?? ""
        return RoutingConfiguration(rules: [], defaultProfileId: fallbackDefaultId)
    }
}
