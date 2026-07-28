import Foundation
import Testing
@testable import BlockListCore

@Suite("Performance smoke test")
struct PerformanceSmokeTests {
    @Test("a 100k-entry list inserts and looks up quickly, ruling out accidental linear-scan behavior")
    func handlesLargeListEfficiently() {
        let trie = DomainTrie()
        for i in 0..<100_000 {
            trie.insert("tracker\(i).example\(i % 500).com")
        }
        #expect(trie.count == 100_000)

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in 0..<10_000 {
                _ = trie.contains(host: "sub.tracker\(i).example\(i % 500).com")
                _ = trie.contains(host: "definitely-not-blocked-\(i).invalid")
            }
        }

        // This is a smoke test for gross regressions (e.g. an accidentally
        // O(list size) lookup), not a strict microbenchmark -- true
        // sub-microsecond-per-lookup claims aren't reliably assertable in a
        // shared CI/dev-machine environment without a dedicated
        // benchmarking harness. 20,000 lookups against a 100k-entry trie
        // completing well under a second here rules out anything close to
        // linear-in-list-size behavior; a real O(labels) trie walk should
        // clear this by a wide margin.
        #expect(elapsed < .seconds(2))
    }
}
