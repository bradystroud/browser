import Foundation
import WebKit

// ContentRuleListBuilder and ContentRuleListBisector come from
// Packages/WebEngineCore, compiled into this target directly (see
// BROWSER_WEBENGINE_CORE_SRCS in Sources/App/CMakeLists.txt).

/// Compiles and attaches the WebKit engine's content-blocking rule lists.
///
/// Each profile's rules are split into chunks by `ContentRuleListBuilder` and
/// stored in `WKContentRuleListStore` as `content-blocker.<profile>.<n>`, with
/// `n` counting the lists that compiled. A chunk WebKit rejects is bisected so
/// only the rules it refuses are left out. If nothing compiles at all, the
/// lists from the last successful compile stay attached: a bad update never
/// turns blocking off.
extension WebKitEngine {
    /// Bumped by every update for a profile. A compile finishing under an
    /// older value has been superseded (or the profile was disabled while
    /// it ran) and must not attach or delete anything.
    private static var contentBlockingGenerations: [String: Int] = [:]

    private static let maxLoggedRejections = 10

    static func compileContentBlocking(domains: [String], profileSettings: [String: EngineProfileBlockingSettings]) {
        guard let store = contentRuleListStore else { return }
        for (profileName, settings) in profileSettings {
            let generation = (contentBlockingGenerations[profileName] ?? 0) + 1
            contentBlockingGenerations[profileName] = generation
            guard settings.enabled else {
                compiledContentRuleLists.removeValue(forKey: profileName)
                liveTabsByProfile[profileName]?.allObjects.forEach { $0.applyContentRuleLists([]) }
                removeStaleRuleLists(profileName: profileName, keeping: [], generation: generation, store: store)
                continue
            }
            let started = Date()
            let output = ContentRuleListBuilder.build(blockedDomains: domains, allowlistedHosts: settings.allowlistedHosts)
            let isCurrent = { contentBlockingGenerations[profileName] == generation }
            compileChunks(output.lists, profileName: profileName, store: store, isCurrent: isCurrent) { compiled, rejectedRules in
                let elapsed = Date().timeIntervalSince(started) * 1000
                NSLog("Browser: WebKit content blocking for profile %@: %ld rules in %ld chunks, %ld lists attached, %ld rules rejected, %ld domains dropped, %.0f ms",
                      profileName, output.ruleCount, output.lists.count, compiled.count, rejectedRules, output.droppedDomains.count, elapsed)
                if compiled.isEmpty && output.ruleCount > 0 {
                    // Leaves the previous lists attached and in the store.
                    NSLog("Browser: WebKit content blocking for profile %@: no rule list compiled, keeping the previous one", profileName)
                    return
                }
                let lists = compiled.map(\.list)
                compiledContentRuleLists[profileName] = lists
                liveTabsByProfile[profileName]?.allObjects.forEach { $0.applyContentRuleLists(lists) }
                removeStaleRuleLists(profileName: profileName, keeping: Set(compiled.map(\.identifier)),
                                     generation: generation, store: store)
            }
        }
    }

    /// Compiles `chunks` one after another, bisecting any that WebKit
    /// rejects, and reports every list that compiled plus how many rules
    /// were left out. Stops without calling `completion` once `isCurrent`
    /// turns false.
    private static func compileChunks(
        _ chunks: [String],
        profileName: String,
        store: WKContentRuleListStore,
        isCurrent: @escaping () -> Bool,
        completion: @escaping (_ compiled: [(identifier: String, list: WKContentRuleList)], _ rejectedRules: Int) -> Void
    ) {
        var compiled: [(identifier: String, list: WKContentRuleList)] = []
        var rejectedRules = 0
        var loggedRejections = 0

        func identifier() -> String {
            ContentRuleListIdentifier.make(profileName: profileName, index: compiled.count)
        }

        func compileChunk(at index: Int) {
            guard isCurrent() else { return }
            guard index < chunks.count else {
                completion(compiled, rejectedRules)
                return
            }
            let chunk = chunks[index]
            let id = identifier()
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: chunk) { list, error in
                if let list {
                    compiled.append((id, list))
                    compileChunk(at: index + 1)
                    return
                }
                NSLog("Browser: WebKit content blocking chunk %ld for profile %@ failed to compile, bisecting: %@",
                      index, profileName, error?.localizedDescription ?? "unknown error")
                guard let rules = ContentRuleListBisector.rules(inList: chunk) else {
                    compileChunk(at: index + 1)
                    return
                }
                let wholeChunk = 0..<rules.count
                ContentRuleListBisector.run(ruleCount: rules.count, compile: { range, done in
                    // The whole chunk has already failed just above.
                    guard range != wholeChunk else { return done(nil) }
                    let id = identifier()
                    let json = ContentRuleListBisector.list(fromRules: rules[range])
                    store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, _ in
                        // Appended straight away so the next piece gets the
                        // next identifier; pieces arrive in rule order.
                        if let list {
                            compiled.append((id, list))
                        }
                        done(list)
                    }
                }, completion: { (result: ContentRuleListBisector.Result<WKContentRuleList>) in
                    for range in result.rejected {
                        rejectedRules += range.count
                        guard loggedRejections < maxLoggedRejections else { continue }
                        loggedRejections += 1
                        if range.count == 1 {
                            NSLog("Browser: WebKit content blocking skipped a rule WebKit rejects for profile %@: %@",
                                  profileName, rules[range.lowerBound])
                        } else {
                            NSLog("Browser: WebKit content blocking gave up bisecting %ld rules for profile %@",
                                  range.count, profileName)
                        }
                    }
                    compileChunk(at: index + 1)
                })
            }
        }

        compileChunk(at: 0)
    }

    /// Deletes this profile's stored rule lists other than `keeping`,
    /// including the pre-chunking `content-blocker.<profile>` identifier.
    private static func removeStaleRuleLists(profileName: String, keeping: Set<String>, generation: Int, store: WKContentRuleListStore) {
        store.getAvailableContentRuleListIdentifiers { identifiers in
            guard contentBlockingGenerations[profileName] == generation else { return }
            for identifier in identifiers ?? [] where !keeping.contains(identifier)
                && ContentRuleListIdentifier.isIdentifier(identifier, ownedBy: profileName) {
                store.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
        }
    }
}

extension WebKitTab {
    /// Replaces the tab's content-blocking lists; an empty array detaches them.
    func applyContentRuleLists(_ lists: [WKContentRuleList]) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        lists.forEach(controller.add)
    }
}
