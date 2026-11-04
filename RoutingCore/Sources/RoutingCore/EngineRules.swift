import Foundation

/// A rendering engine a page can be shown in. The raw values are what
/// `engine-rules.json` stores, and match the app's own `EngineChoice` names
/// (`--engine cef|webkit`), so the two map one-to-one by raw value.
public enum SiteEngine: String, Codable, CaseIterable, Sendable {
    case chromium = "cef"
    case webkit
}

/// "Pages on this site open in this engine." Global, not per profile: what
/// decides it is the site (it needs FairPlay, it needs an extension only
/// WebKit can run), and that is the same whichever profile visits it.
public struct EngineSiteRule: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// `example.com`, optionally followed by a path prefix
    /// (`amazon.com/gp/video`). A host covers its subdomains too; a leading
    /// `*.` is accepted and means the same thing. See `EngineSitePattern`.
    public var pattern: String
    public var engine: SiteEngine
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, pattern: String, engine: SiteEngine, isEnabled: Bool = true) {
        self.id = id
        self.pattern = pattern
        self.engine = engine
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, engine, isEnabled
    }

    /// Only `pattern` and `engine` are required. An engine name this version
    /// does not know throws, which drops that one rule (see
    /// EngineRuleConfiguration's decoder), never the file.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        pattern = try container.decode(String.self, forKey: .pattern)
        engine = try container.decode(SiteEngine.self, forKey: .engine)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// A parsed `EngineSiteRule.pattern`.
public struct EngineSitePattern: Equatable, Sendable {
    /// Lowercased ASCII (punycode), no leading `*.` and no trailing dot.
    public let domain: String
    /// Starts with `/`, or nil to match every path on the site.
    public let pathPrefix: String?

    /// nil for a pattern with no usable host -- an empty string, a bare `*`,
    /// anything with a scheme other than http(s) -- or with a port, which
    /// could never match: `matches(host:path:)` is given hosts, never ports.
    public init?(_ pattern: String) {
        var text = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = text.range(of: "://") {
            let scheme = text[..<schemeRange.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
            text = String(text[schemeRange.upperBound...])
        }
        if text.hasPrefix("*.") { text.removeFirst(2) }
        let host: String
        var path: String?
        if let slash = text.firstIndex(of: "/") {
            host = String(text[..<slash])
            // A trailing slash is dropped, so `amazon.com/gp/video/` means
            // what `amazon.com/gp/video` does and also covers the bare path.
            var rest = Substring(text[slash...])
            while rest.hasSuffix("/") { rest = rest.dropLast() }
            path = rest.isEmpty ? nil : String(rest)
        } else {
            host = text
        }
        let domain = RuleMatcher.normalizedDomain(host)
        guard !domain.isEmpty, !domain.contains("*"), !domain.contains(" "), !domain.contains(":") else { return nil }
        self.domain = domain
        self.pathPrefix = path
    }

    public func matches(host: String, path: String) -> Bool {
        let host = RuleMatcher.normalizedDomain(host)
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        guard let pathPrefix else { return true }
        let path = path.isEmpty ? "/" : path
        guard path.lowercased().hasPrefix(pathPrefix.lowercased()) else { return false }
        // `/gp/video` covers `/gp/video` and `/gp/video/...`, not `/gp/videos`.
        if path.count == pathPrefix.count { return true }
        let next = path[path.index(path.startIndex, offsetBy: pathPrefix.count)]
        return next == "/" || next == "?" || next == "#"
    }
}

/// Rules that ship with the app. Shown to the user beside their own and can
/// be switched off one by one, but not edited or deleted -- a disabled one
/// is remembered by id, so a later version can update a built-in's pattern
/// without losing the user's choice.
public enum BuiltInEngineRules {
    /// Streaming services whose video is DRM-protected. This app's CEF
    /// build has neither the proprietary codecs nor a signed Widevine CDM,
    /// so these play only in WebKit, which has FairPlay.
    public static let all: [EngineSiteRule] = [
        EngineSiteRule(id: "builtin.netflix", pattern: "netflix.com", engine: .webkit),
        EngineSiteRule(id: "builtin.disneyplus", pattern: "disneyplus.com", engine: .webkit),
        EngineSiteRule(id: "builtin.max", pattern: "max.com", engine: .webkit),
        // Where max.com redirects.
        EngineSiteRule(id: "builtin.hbomax", pattern: "hbomax.com", engine: .webkit),
        EngineSiteRule(id: "builtin.primevideo", pattern: "primevideo.com", engine: .webkit),
        EngineSiteRule(id: "builtin.amazon-video", pattern: "amazon.com/gp/video", engine: .webkit),
    ] + amazonVideoStorefronts.map { domain in
        EngineSiteRule(id: "builtin.amazon-video.\(domain)", pattern: "\(domain)/gp/video", engine: .webkit)
    } + [
        EngineSiteRule(id: "builtin.apple-tv", pattern: "tv.apple.com", engine: .webkit),
        // The whole domain, not just the web player: signing in happens on
        // accounts.spotify.com, and its cookies must land in the engine
        // that plays.
        EngineSiteRule(id: "builtin.spotify", pattern: "spotify.com", engine: .webkit),
    ]

    /// Amazon's regional stores, each of which serves Prime Video under
    /// `/gp/video`. amazon.com has its own rule above.
    static let amazonVideoStorefronts = [
        "amazon.co.uk", "amazon.de", "amazon.co.jp", "amazon.ca", "amazon.com.au",
        "amazon.fr", "amazon.it", "amazon.es", "amazon.in", "amazon.com.mx", "amazon.com.br",
    ]

    public static func isBuiltIn(_ id: String) -> Bool {
        all.contains { $0.id == id }
    }
}

/// Everything `engine-rules.json` holds. The default engine is not here: it
/// is an ordinary preference, and `--engine` can override it for one launch.
public struct EngineRuleConfiguration: Codable, Equatable, Sendable {
    public var userRules: [EngineSiteRule]
    public var disabledBuiltInIds: Set<String>

    public init(userRules: [EngineSiteRule] = [], disabledBuiltInIds: Set<String> = []) {
        self.userRules = userRules
        self.disabledBuiltInIds = disabledBuiltInIds
    }

    private enum CodingKeys: String, CodingKey {
        case userRules, disabledBuiltInIds
    }

    /// Decodes each rule on its own, skipping one it cannot read (an engine
    /// a later version added, a hand edit gone wrong) and keeping the rest.
    /// A missing key is an empty list. Anything stricter would fail the
    /// whole file, which the store sets aside as corrupt -- losing every
    /// rule over one bad entry.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        userRules = (try container.decodeIfPresent([SkippingInvalid<EngineSiteRule>].self, forKey: .userRules) ?? [])
            .compactMap(\.value)
        disabledBuiltInIds = try container.decodeIfPresent(Set<String>.self, forKey: .disabledBuiltInIds) ?? []
    }

    /// "Always open this site in ...": the user's rule for `pattern` now
    /// sends it to `engine`, and goes first, ahead of every older rule --
    /// including a broader one (`example.com` against `docs.example.com`)
    /// that would otherwise keep winning. A rule already written for the
    /// same site, however it was spelled (`https://x.com/`, `*.x.com`), is
    /// moved and retargeted rather than duplicated. Returns the rule.
    @discardableResult
    public mutating func setEngine(_ engine: SiteEngine, forPattern pattern: String) -> EngineSiteRule {
        let parsed = EngineSitePattern(pattern)
        let existing = userRules.firstIndex { rule in
            if let parsed { return EngineSitePattern(rule.pattern) == parsed }
            return rule.pattern.caseInsensitiveCompare(pattern) == .orderedSame
        }
        var rule = existing.map { userRules.remove(at: $0) } ?? EngineSiteRule(pattern: pattern, engine: engine)
        rule.engine = engine
        rule.isEnabled = true
        userRules.insert(rule, at: 0)
        return rule
    }

    /// Evaluation order: the user's own rules first, in their order, then the
    /// built-ins, so a user rule for the same site always wins. Built-ins
    /// carry their enabled state from `disabledBuiltInIds`.
    public var effectiveRules: [EngineSiteRule] {
        userRules + BuiltInEngineRules.all.map { rule in
            var rule = rule
            rule.isEnabled = !disabledBuiltInIds.contains(rule.id)
            return rule
        }
    }
}

public enum EngineRuleMatcher {
    /// The first enabled rule matching `url`, or nil. Only http(s) URLs are
    /// ever matched: a `data:` start page, `about:blank` or a `file:` URL
    /// belongs to no site.
    public static func matchingRule(for url: String, in rules: [EngineSiteRule]) -> EngineSiteRule? {
        guard let components = URLComponents(string: url),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        let path = components.percentEncodedPath
        for rule in rules where rule.isEnabled {
            if let pattern = EngineSitePattern(rule.pattern), pattern.matches(host: host, path: path) {
                return rule
            }
        }
        return nil
    }
}

/// Why a tab is about to show `url`. Decides how much weight the tab's
/// current engine gets against the rules.
public enum EngineNavigationTrigger: Equatable, Sendable {
    /// A tab that has no page yet: a new tab, a link opened in a new tab, a
    /// routed link, a restored tab.
    case newTab
    /// The user (or the app on their behalf) asked this tab to go somewhere:
    /// the omnibox, a bookmark, a history entry, `browser open`.
    case explicitLoad
    /// The page went somewhere by itself: a link click, a form, a redirect,
    /// script.
    case pageNavigation
}

/// "Reopen in WebKit/Chromium": the user's own choice for one tab, which
/// rules do not override while it lasts. Tied to the site it was made on.
public struct EngineOverride: Equatable, Sendable {
    public let engine: SiteEngine
    /// The host the override was made on, normalized; nil when the tab
    /// showed no http(s) page then (the start page), so it holds only until
    /// the tab first goes anywhere explicitly.
    public let host: String?

    public init(engine: SiteEngine, url: String) {
        self.engine = engine
        self.host = URLComponents(string: url)?.host.flatMap(Self.siteHost)
    }

    /// An override read back from a saved session, as `engine` and `host`
    /// were when it was made.
    public init(engine: SiteEngine, host: String?) {
        self.engine = engine
        self.host = host.flatMap(Self.siteHost)
    }

    /// The override's site and its subdomains -- never a parent domain: an
    /// override made on `user.github.io` says nothing about `github.io`.
    func covers(_ url: String) -> Bool {
        guard let host, let urlHost = URLComponents(string: url)?.host, let normalized = Self.siteHost(urlHost) else {
            return false
        }
        return normalized == host || normalized.hasSuffix("." + host)
    }

    /// Normalized, without a leading `www.`, so an override made on
    /// `www.example.com` holds on `example.com` too.
    private static func siteHost(_ host: String) -> String? {
        var normalized = RuleMatcher.normalizedDomain(host)
        if normalized.hasPrefix("www.") { normalized.removeFirst(4) }
        return normalized.isEmpty ? nil : normalized
    }
}

/// Decodes to nil instead of throwing, so one bad element of an array does
/// not fail the array.
struct SkippingInvalid<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

public struct EngineDecision: Equatable, Sendable {
    public let engine: SiteEngine
    /// The rule that decided it, if one did.
    public let rule: EngineSiteRule?
    /// The tab's override no longer applies and should be dropped.
    public let clearsOverride: Bool
}

/// Which engine a tab should show a URL in. Pure policy, so the app's tabs
/// and the tests read the same rules:
///
/// - A rule pulls a page into its engine, whatever the trigger.
/// - Without a rule, a new tab or an explicit load uses the default engine,
///   but a page's own navigation stays in the tab's current engine. A site
///   sent to WebKit by a rule therefore keeps its sign-in or checkout hop to
///   another domain in WebKit, where its cookies are, instead of bouncing
///   back to Chromium halfway through.
/// - A user override ("Reopen in ...") beats rules: every page navigation
///   stays in its engine, and an explicit load keeps it only on the same
///   site. Going anywhere else explicitly drops it.
/// - A URL that belongs to no site (start page, `about:`, `data:`, `file:`)
///   stays in the current engine.
public enum EngineSwitchPolicy {
    public static func decide(
        url: String,
        trigger: EngineNavigationTrigger,
        currentEngine: SiteEngine?,
        override: EngineOverride?,
        rules: [EngineSiteRule],
        defaultEngine: SiteEngine
    ) -> EngineDecision {
        let isWeb: Bool = {
            guard let scheme = URLComponents(string: url)?.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }()
        guard isWeb else {
            return EngineDecision(engine: currentEngine ?? override?.engine ?? defaultEngine, rule: nil, clearsOverride: false)
        }

        if let override {
            if trigger == .pageNavigation || override.covers(url) {
                return EngineDecision(engine: override.engine, rule: nil, clearsOverride: false)
            }
        }
        let clears = override != nil

        if let rule = EngineRuleMatcher.matchingRule(for: url, in: rules) {
            return EngineDecision(engine: rule.engine, rule: rule, clearsOverride: clears)
        }
        if trigger == .pageNavigation, let currentEngine {
            return EngineDecision(engine: currentEngine, rule: nil, clearsOverride: clears)
        }
        return EngineDecision(engine: defaultEngine, rule: nil, clearsOverride: clears)
    }
}

/// Stops two rules from bouncing one tab between engines forever (a site
/// in one engine redirecting to a site ruled into the other, and back).
/// Allows `limit` automatic swaps inside `window` seconds, then refuses
/// until the window has passed.
public struct EngineSwapThrottle: Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var recent: [TimeInterval] = []

    public init(limit: Int = 3, window: TimeInterval = 10) {
        self.limit = limit
        self.window = window
    }

    /// Records a swap at `now` and says whether it may go ahead.
    public mutating func allow(at now: TimeInterval) -> Bool {
        recent.removeAll { now - $0 > window }
        guard recent.count < limit else { return false }
        recent.append(now)
        return true
    }
}
