import Foundation

/// Persists the ordered rule list + default-profile fallback as JSON under
/// `CommandLineArgs.sessionAndProfilesMetadataDirectory()`'s `routing.json`
/// (`~/Library/Application Support/Browser/routing.json` for a normal,
/// unflagged launch), mirroring ProfileManager's pattern. `RoutingRule`/
/// `RoutingConfiguration` are the pure model types from RoutingCore (compiled
/// directly into this target -- see Sources/App/CMakeLists.txt).
///
/// Previously computed its own `.applicationSupportDirectory` + "Browser"
/// path directly, bypassing `CommandLineArgs`/`ProfilesRootResolver`
/// entirely -- unlike every other per-launch store (browser-1rp fixed this
/// exact class of bug for session.json/profiles.json, but missed this file,
/// which was apparently added independently), so an agent's "isolated"
/// `--profiles-root` scratch launch silently read *and wrote* Brady's real
/// routing.json the whole time, while `browser route-test`
/// (RouteTestEngine.swift) already correctly assumed routing.json lives
/// under the profiles-root-scoped metadata directory -- found auditing
/// every store's path resolution for browser-le4 (state durability).
final class RoutingRulesStore {
    static let shared = RoutingRulesStore()

    private let fileURL: URL
    private(set) var configuration: RoutingConfiguration

    private init() {
        let dir = URL(fileURLWithPath: CommandLineArgs.sessionAndProfilesMetadataDirectory())
        fileURL = dir.appendingPathComponent("routing.json")

        if let decoded = JSONFile<RoutingConfiguration?>(url: fileURL).load(default: nil) {
            configuration = decoded
        } else {
            // defaultProfileId is a Profile.id (UUID), not a name -- resolve
            // (and, on a brand-new install, implicitly create) the "default"
            // profile now rather than persisting its name string, which
            // would never match a profile(id:) lookup.
            let defaultProfile = ProfileManager.shared.profileOrCreate(named: ProfileManager.defaultProfileName)
            configuration = RoutingConfiguration(rules: [], defaultProfileId: defaultProfile.id)
        }
    }

    var rules: [RoutingRule] { configuration.rules }
    var defaultProfileId: String { configuration.defaultProfileId }

    func setDefaultProfileId(_ profileId: String) {
        configuration.defaultProfileId = profileId
        save()
    }

    func addRule(_ rule: RoutingRule) {
        configuration.rules.append(rule)
        save()
    }

    func updateRule(_ rule: RoutingRule) {
        guard let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        configuration.rules[index] = rule
        save()
    }

    func deleteRule(id: UUID) {
        configuration.rules.removeAll { $0.id == id }
        save()
    }

    /// Moves the rule at `index` up (`-1`) or down (`+1`) one position in the
    /// evaluation order. No-op at either end of the list.
    func moveRule(at index: Int, by offset: Int) {
        let newIndex = index + offset
        guard configuration.rules.indices.contains(index), configuration.rules.indices.contains(newIndex) else { return }
        configuration.rules.swapAt(index, newIndex)
        save()
    }

    private func save() {
        JSONFile<RoutingConfiguration>(url: fileURL).save(configuration)
    }
}
