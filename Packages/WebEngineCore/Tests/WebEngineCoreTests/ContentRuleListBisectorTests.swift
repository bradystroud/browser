import XCTest
@testable import WebEngineCore

final class ContentRuleListBisectorTests: XCTestCase {
    /// Compiles synchronously; a range fails if it contains any bad index.
    private func run(ruleCount: Int, bad: Set<Int>, maxAttempts: Int = ContentRuleListBisector.defaultMaxAttempts)
        -> ContentRuleListBisector.Result<Range<Int>> {
        var output: ContentRuleListBisector.Result<Range<Int>>?
        ContentRuleListBisector.run(ruleCount: ruleCount, maxAttempts: maxAttempts, compile: { range, done in
            done(range.contains(where: bad.contains) ? nil : range)
        }, completion: { output = $0 })
        return output!
    }

    func testCleanListCompilesInOneAttempt() {
        let result = run(ruleCount: 1000, bad: [])
        XCTAssertEqual(result.attempts, 1)
        XCTAssertEqual(result.compiled.map(\.range), [0..<1000])
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testEmptyListNeverCompiles() {
        let result = run(ruleCount: 0, bad: [])
        XCTAssertEqual(result.attempts, 0)
        XCTAssertTrue(result.compiled.isEmpty)
    }

    func testSingleBadRuleIsIsolatedAndEverythingElseKept() {
        let result = run(ruleCount: 50_000, bad: [31_337])
        XCTAssertEqual(result.rejected, [31_337..<31_338])
        XCTAssertEqual(result.compiled.reduce(0) { $0 + $1.range.count }, 49_999)
        // Binary search depth: roughly two compiles per halving.
        XCTAssertLessThanOrEqual(result.attempts, 2 * 17 + 1)
    }

    func testCompiledRangesAreInOrderAndDisjoint() {
        let result = run(ruleCount: 100, bad: [0, 7, 50, 99])
        XCTAssertEqual(result.rejected.sorted { $0.lowerBound < $1.lowerBound }, [0..<1, 7..<8, 50..<51, 99..<100])
        var covered = IndexSet()
        var previousEnd = 0
        for (range, _) in result.compiled {
            XCTAssertGreaterThanOrEqual(range.lowerBound, previousEnd)
            previousEnd = range.upperBound
            covered.insert(integersIn: range)
        }
        XCTAssertEqual(covered.count, 96)
    }

    func testAttemptBudgetStopsSplittingAnAllBadList() {
        let result = run(ruleCount: 10_000, bad: Set(0..<10_000), maxAttempts: 20)
        XCTAssertTrue(result.compiled.isEmpty)
        XCTAssertEqual(result.rejectedRuleCount, 10_000)
        // After the budget, only the ranges already queued get one try each.
        XCTAssertLessThan(result.attempts, 20 + 20)
    }

    func testRulesRoundTrip() throws {
        let output = ContentRuleListBuilder.build(blockedDomains: ["a.com", "b.com", "c.com"], allowlistedHosts: ["x.org"])
        let rules = try XCTUnwrap(ContentRuleListBisector.rules(inList: output.lists[0]))
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(ContentRuleListBisector.list(fromRules: rules), output.lists[0])
        XCTAssertEqual(ContentRuleListBisector.list(fromRules: rules[1..<2]).first, "[")
        XCTAssertNil(ContentRuleListBisector.rules(inList: "not json"))
    }

    func testIdentifierOwnership() {
        XCTAssertEqual(ContentRuleListIdentifier.make(profileName: "Work", index: 2), "content-blocker.Work.2")
        XCTAssertTrue(ContentRuleListIdentifier.isIdentifier("content-blocker.Work.0", ownedBy: "Work"))
        XCTAssertTrue(ContentRuleListIdentifier.isIdentifier("content-blocker.Work.12", ownedBy: "Work"))
        XCTAssertTrue(ContentRuleListIdentifier.isIdentifier("content-blocker.Work", ownedBy: "Work"))
        XCTAssertFalse(ContentRuleListIdentifier.isIdentifier("content-blocker.Workshop.0", ownedBy: "Work"))
        XCTAssertFalse(ContentRuleListIdentifier.isIdentifier("content-blocker.Work.x", ownedBy: "Work"))
        XCTAssertFalse(ContentRuleListIdentifier.isIdentifier("content-blocker.Work.", ownedBy: "Work"))
        // "a.1"'s lists are not "a"'s, and "a"'s second list is not "a.1"'s legacy one.
        XCTAssertFalse(ContentRuleListIdentifier.isIdentifier("content-blocker.a.1.0", ownedBy: "a"))
        XCTAssertTrue(ContentRuleListIdentifier.isIdentifier("content-blocker.a.1.0", ownedBy: "a.1"))
        XCTAssertFalse(ContentRuleListIdentifier.isIdentifier("content-blocker.a.1", ownedBy: "a.1"))
    }
}
