import Foundation

extension Notification.Name {
    /// The site rules or the default engine changed.
    static let engineRulesDidChange = Notification.Name("EngineRulesDidChange")
}

/// Which engine each site opens in: the user's own rules plus the built-in
/// ones, persisted as `engine-rules.json` beside `routing.json` (so a
/// `--profiles-root` scratch launch gets its own copy).
///
/// Global, not per profile. The reasons a site needs a particular engine
/// belong to the site -- its video needs FairPlay, the extension it needs
/// runs only on WebKit, it breaks in one engine -- and are the same for
/// every profile that visits it. A per-profile rule would make the user
/// say the same thing once per profile.
final class EngineRulesStore {
    static let shared = EngineRulesStore()

    private let fileURL: URL
    private(set) var configuration: EngineRuleConfiguration

    private init() {
        let dir = URL(fileURLWithPath: CommandLineArgs.sessionAndProfilesMetadataDirectory())
        fileURL = dir.appendingPathComponent("engine-rules.json")
        configuration = JSONFile<EngineRuleConfiguration?>(url: fileURL).load(default: nil) ?? EngineRuleConfiguration()
    }

    /// The rules in evaluation order, built-ins included -- see
    /// EngineRuleConfiguration.effectiveRules.
    var effectiveRules: [EngineSiteRule] { configuration.effectiveRules }

    var userRules: [EngineSiteRule] { configuration.userRules }

    func addRule(_ rule: EngineSiteRule) {
        configuration.userRules.append(rule)
        save()
    }

    /// Adds a rule for `pattern`, or retargets the user's existing rule for
    /// exactly that pattern, so "always open this site in ..." never piles
    /// up duplicates.
    func setEngine(_ engine: SiteEngine, forPattern pattern: String) {
        if let index = configuration.userRules.firstIndex(where: { $0.pattern.caseInsensitiveCompare(pattern) == .orderedSame }) {
            configuration.userRules[index].engine = engine
            configuration.userRules[index].isEnabled = true
            save()
        } else {
            addRule(EngineSiteRule(pattern: pattern, engine: engine))
        }
    }

    func updateRule(_ rule: EngineSiteRule) {
        if BuiltInEngineRules.isBuiltIn(rule.id) {
            if rule.isEnabled {
                configuration.disabledBuiltInIds.remove(rule.id)
            } else {
                configuration.disabledBuiltInIds.insert(rule.id)
            }
        } else if let index = configuration.userRules.firstIndex(where: { $0.id == rule.id }) {
            configuration.userRules[index] = rule
        } else {
            return
        }
        save()
    }

    /// Built-in rules cannot be deleted, only switched off.
    func deleteRule(id: String) {
        guard !BuiltInEngineRules.isBuiltIn(id) else { return }
        configuration.userRules.removeAll { $0.id == id }
        save()
    }

    /// The engine a tab should show `url` in -- see EngineSwitchPolicy for
    /// the rules this applies.
    func decide(url: String, trigger: EngineNavigationTrigger, currentEngine: EngineChoice?, override: EngineOverride?) -> (engine: EngineChoice, clearsOverride: Bool) {
        let decision = EngineSwitchPolicy.decide(
            url: url,
            trigger: trigger,
            currentEngine: currentEngine.map(\.siteEngine),
            override: override,
            rules: effectiveRules,
            defaultEngine: CommandLineArgs.defaultEngine().siteEngine)
        return (EngineChoice(decision.engine), decision.clearsOverride)
    }

    private func save() {
        JSONFile<EngineRuleConfiguration>(url: fileURL).save(configuration)
        NotificationCenter.default.post(name: .engineRulesDidChange, object: nil)
    }
}

extension EngineChoice {
    init(_ siteEngine: SiteEngine) {
        self = EngineChoice(rawValue: siteEngine.rawValue) ?? .cef
    }

    var siteEngine: SiteEngine {
        SiteEngine(rawValue: rawValue) ?? .chromium
    }
}
