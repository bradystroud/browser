import XCTest
@testable import WebKitAdapter

final class FindTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/find": .html("""
                <!DOCTYPE html><title>Find</title>
                <p>needle one</p>
                <p>two <b>needle</b> and a needle</p>
                <div>needle</div>
                <p>NEEDLE shouting</p>
                <p>no match here</p>
                <p style="display:none">needle hidden</p>
                """),
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        loadAndWaitForCommit(server.url("/find"))
    }

    private func find(_ text: String, forward: Bool = true, matchCase: Bool = false, findNext: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) -> (count: Int, ordinal: Int)? {
        let before = recorder.findResults.count
        tab.find(text, forward: forward, matchCase: matchCase, findNext: findNext)
        guard waitUntil("find result for \(text)", file: file, line: line, { recorder.findResults.count > before }) else { return nil }
        let result = recorder.findResults[recorder.findResults.count - 1]
        XCTAssertTrue(result.isFinal, file: file, line: line)
        return (result.count, result.ordinal)
    }

    func testCaseInsensitiveCountIncludesEveryVisibleMatch() {
        let result = find("needle")
        XCTAssertEqual(result?.count, 5)
        XCTAssertEqual(result?.ordinal, 1)
    }

    func testCaseSensitiveCount() {
        XCTAssertEqual(find("needle", matchCase: true)?.count, 4)
        XCTAssertEqual(find("NEEDLE", matchCase: true)?.count, 1)
    }

    func testFindNextAdvancesAndWraps() {
        XCTAssertEqual(find("needle")?.ordinal, 1)
        XCTAssertEqual(find("needle", findNext: true)?.ordinal, 2)
        XCTAssertEqual(find("needle", findNext: true)?.ordinal, 3)
        XCTAssertEqual(find("needle", forward: false, findNext: true)?.ordinal, 2)
    }

    func testNoMatchReportsZero() {
        let result = find("haystack")
        XCTAssertEqual(result?.count, 0)
        XCTAssertEqual(result?.ordinal, 0)
    }
}
