import XCTest
import WebKit
import BlockListCore
@testable import WebEngineCore

/// Compiles the builder's output through a real `WKContentRuleListStore`,
/// so the validator's idea of WebKit's regex subset is checked against
/// WebKit itself rather than only against our own reading of it.
@MainActor
final class WebKitCompileTests: XCTestCase {
    private var storeDirectory: URL!
    private var store: WKContentRuleListStore!

    override func setUp() async throws {
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebEngineCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        store = try XCTUnwrap(WKContentRuleListStore(url: storeDirectory))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    func testStarterListCompiles() async throws {
        let blockList = BlockList()
        blockList.loadStarterList()
        let output = ContentRuleListBuilder.build(blockedDomains: blockList.allDomains(), allowlistedHosts: ["news.example"])
        XCTAssertEqual(output.lists.count, 1)
        for (index, json) in output.lists.enumerated() {
            let error = await compile(json, identifier: "starter-\(index)")
            XCTAssertNil(error, "\(error.map { String(describing: $0) } ?? "")")
        }
    }

    func testPreviousDisjunctionTemplateIsRejectedByWebKit() async {
        // Reproduces the original failure: WKErrorDomain error 6,
        // "Disjunctions are not supported yet".
        let json = #"[{"trigger":{"url-filter":"^https?://([a-z0-9-]+\\.)*mouseflow\\.com([/:]|$)"},"action":{"type":"block"}}]"#
        let error = await compile(json, identifier: "old")
        XCTAssertNotNil(error)
        XCTAssertNotNil(ContentBlockerRegex.validate("^https?://([a-z0-9-]+\\.)*mouseflow\\.com([/:]|$)"))
    }

    func testExpandedDisjunctionCompiles() async throws {
        let filters = try XCTUnwrap(ContentBlockerRegex.expandDisjunctions("^https?://ads\\.(foo|bar)\\.com[/:]"))
        let rules = filters.map { #"{"trigger":{"url-filter":"\#($0.replacingOccurrences(of: "\\", with: "\\\\"))"},"action":{"type":"block"}}"# }
        let error = await compile("[" + rules.joined(separator: ",") + "]", identifier: "expanded")
        XCTAssertNil(error)
    }

    /// Everything the validator accepts must compile: that is the direction
    /// that keeps a list from being rejected wholesale. (The validator is
    /// deliberately stricter than WebKit in places -- WebKit takes `(a)\1`, `(?:a)`
    /// and `a*?` without complaint, but neither means what it says there.)
    func testEveryAcceptedPatternCompiles() async {
        for (index, pattern) in [
            "^https?://([a-z0-9-]+\\.)*mouseflow\\.com[/:]", "ads", "^https://example\\.com/$",
            "[^a-z]+x?", "a.*b", "\\|literal-pipe\\{", "((ab)+c)*",
        ].enumerated() {
            XCTAssertNil(ContentBlockerRegex.validate(pattern), pattern)
            let error = await compile(rule(pattern), identifier: "accept-\(index)")
            XCTAssertNil(error, "WebKit rejected \(pattern)")
        }
    }

    /// The syntax WebKit itself refuses is refused by the validator too.
    func testWebKitRejectionsAreAlsoValidatorRejections() async {
        for (index, pattern) in ["a|b", "a{2}", "(?=a)b", "a$b", "\\d+", "exämple"].enumerated() {
            XCTAssertNotNil(ContentBlockerRegex.validate(pattern), pattern)
            let error = await compile(rule(pattern), identifier: "reject-\(index)")
            XCTAssertNotNil(error, "WebKit accepted \(pattern)")
        }
    }

    private func rule(_ pattern: String) -> String {
        let escaped = pattern.replacingOccurrences(of: "\\", with: "\\\\")
        return #"[{"trigger":{"url-filter":"\#(escaped)"},"action":{"type":"block"}}]"#
    }

    private func compile(_ json: String, identifier: String) async -> Error? {
        await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { _, error in
                continuation.resume(returning: error)
            }
        }
    }
}
