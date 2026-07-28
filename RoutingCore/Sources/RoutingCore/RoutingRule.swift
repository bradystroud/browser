import Foundation

/// A single link-routing rule: `{match: {domainGlob?, urlRegex?,
/// sourceBundleIds?}, action: {profileId}}` per
/// docs/plans/2026-07-27-browser-plan.md's M2 scope and
/// docs/research/2026-07-27-link-routing-macos.md's recommended schema.
/// Rules are evaluated in list order by RuleMatcher (first match wins); an
/// absent match field is not evaluated (vacuous true), so a rule with every
/// field nil matches every URL -- a deliberate catch-all escape hatch,
/// equivalent to but orderable ahead of `defaultProfileId`.
public struct RoutingRule: Codable, Equatable, Identifiable {
    public struct Match: Codable, Equatable {
        /// Plain case-insensitive substring match anywhere in the full URL
        /// string -- the simplest mental model, and what most people reach
        /// for first (see browser-hbr: a first-run user typed glob syntax
        /// like `*ssw*` into the regex field, which silently compiled to
        /// never-match). Listed first since it's the primary/expected field.
        public var urlContains: String?
        /// `*.example.com` (subdomain-inclusive: matches example.com and any
        /// subdomain) or a bare `example.com` (matches that host only).
        public var domainGlob: String?
        /// Matched against the full URL string via NSRegularExpression. An
        /// unparseable pattern is treated as a non-match, not a crash --
        /// the rule editor validates this as-you-type instead, so it should
        /// never reach a saved rule in practice.
        public var urlRegex: String?
        /// Bundle identifiers of the app the link was clicked in. Empty/nil
        /// source (sender PID unresolvable, or link opened with no
        /// attributable sender) never satisfies this field.
        public var sourceBundleIds: [String]?

        public init(
            urlContains: String? = nil,
            domainGlob: String? = nil,
            urlRegex: String? = nil,
            sourceBundleIds: [String]? = nil
        ) {
            self.urlContains = urlContains
            self.domainGlob = domainGlob
            self.urlRegex = urlRegex
            self.sourceBundleIds = sourceBundleIds
        }
    }

    public struct Action: Codable, Equatable {
        public var profileId: String

        public init(profileId: String) {
            self.profileId = profileId
        }
    }

    public var id: UUID
    public var match: Match
    public var action: Action

    public init(id: UUID = UUID(), match: Match, action: Action) {
        self.id = id
        self.match = match
        self.action = action
    }
}

/// The full persisted routing configuration: an ordered rule list plus the
/// fallback profile for links no rule matches.
public struct RoutingConfiguration: Codable, Equatable {
    public var rules: [RoutingRule]
    public var defaultProfileId: String

    public init(rules: [RoutingRule] = [], defaultProfileId: String) {
        self.rules = rules
        self.defaultProfileId = defaultProfileId
    }
}
