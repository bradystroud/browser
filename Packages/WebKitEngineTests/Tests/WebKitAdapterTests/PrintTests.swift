import AppKit
import WebKit
import XCTest
@testable import WebKitAdapter

/// A page's own window.print() reaches the tab's print path. The real print
/// sheet is swapped for a recorder: WebKit holds the page's script inside
/// window.print() until the sheet ends, which is what these tests observe.
final class PrintTests: WebKitTabTestCase {
    private var sheets: [NSPrintOperation] = []
    private var endSheet: (() -> Void)?

    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/page": .html("<!DOCTYPE html><title>Invoice</title><p>Total: $42</p>"),
            "/autoprint": .html("""
                <!DOCTYPE html><title>Auto</title>
                <script>window.print(); document.title = 'Printed';</script>
                <p>Order 123</p>
                """),
            "/outer": .html("<!DOCTYPE html><title>Outer</title><iframe src=\"/page\"></iframe>"),
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        sheets = []
        endSheet = nil
        tab.runPrintSheet = { [unowned self] operation, _, done in
            self.sheets.append(operation)
            self.endSheet = done
        }
    }

    /// Starts `body` in the page without waiting for it, since window.print()
    /// does not return until the sheet ends.
    private func startJS(_ body: String) -> () -> Result<Any, Error>? {
        var outcome: Result<Any, Error>?
        tab.webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { outcome = $0 }
        return { outcome }
    }

    func testWindowPrintShowsSheetAndReturnsWhenItEnds() throws {
        loadAndWaitForCommit(server.url("/page"))
        waitUntil("page loaded") { !tab.webView.isLoading }
        let result = startJS("window.print(); return 'returned';")

        waitUntil("print sheet") { sheets.count == 1 }
        settle(0.2)
        XCTAssertNil(result(), "window.print() returned before the sheet ended")

        endSheet?()
        waitUntil("window.print() returned") { result() != nil }
        XCTAssertEqual(try result()?.get() as? String, "returned")
    }

    func testSecondPrintWhileSheetIsUpIsIgnored() throws {
        loadAndWaitForCommit(server.url("/page"))
        waitUntil("page loaded") { !tab.webView.isLoading }
        let result = startJS("window.print(); return true;")
        waitUntil("print sheet") { sheets.count == 1 }

        tab.print()
        settle(0.2)
        XCTAssertEqual(sheets.count, 1)

        endSheet?()
        waitUntil("window.print() returned") { result() != nil }
        tab.print()
        XCTAssertEqual(sheets.count, 2, "a print after the first ended is shown")
    }

    /// WebKit asks mid-parse, with the rest of the page not yet loaded; the
    /// sheet must wait for the whole page rather than print half of it.
    func testPrintDuringLoadWaitsForThePageToFinish() {
        loadAndWaitForCommit(server.url("/autoprint"))
        waitUntil("print sheet") { sheets.count == 1 }
        XCTAssertFalse(tab.webView.isLoading)
        XCTAssertEqual(tab.webView.title, "Printed", "the page's script ran on past print()")
        XCTAssertNotNil(recorder.lastIndex(of: "loading:false"))
        endSheet?()
        settle(0.2)
        XCTAssertEqual(sheets.count, 1)
    }

    func testPrintDuringLoadIsDroppedWhenTheTabNavigatesAway() {
        tab.loadURL(server.url("/autoprint"))
        waitUntil("print requested") { tab.deferredPrint != nil }
        loadAndWaitForCommit(server.url("/page"))
        waitUntil("page loaded") { !tab.webView.isLoading }
        settle(0.3)
        XCTAssertTrue(sheets.isEmpty)
        XCTAssertNil(tab.deferredPrint, "a dropped print must not block the next one")
    }

    func testSubframePrintShowsSheet() {
        loadAndWaitForCommit(server.url("/outer"))
        waitUntil("page loaded") { !tab.webView.isLoading }
        tab.webView.evaluateJavaScript("document.querySelector('iframe').contentWindow.print()", completionHandler: nil)
        waitUntil("print sheet") { sheets.count == 1 }
        endSheet?()
    }

    /// Switching tabs or closing one takes its web view out of the window;
    /// the page must not be left blocked inside window.print().
    func testLeavingTheWindowEndsThePrint() throws {
        loadAndWaitForCommit(server.url("/page"))
        waitUntil("page loaded") { !tab.webView.isLoading }
        let result = startJS("window.print(); return 'returned';")
        waitUntil("print sheet") { sheets.count == 1 }

        tab.webView.removeFromSuperview()
        waitUntil("window.print() returned") { result() != nil }
        XCTAssertEqual(try result()?.get() as? String, "returned")
    }
}
