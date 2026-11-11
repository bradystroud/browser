import XCTest
@testable import WebKitAdapter

/// `mainDocumentLoad` is what `browser page open/navigate/reload` reports,
/// so an agent learns that a page is a server's error, not the page it
/// asked for.
final class MainDocumentLoadTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/ok": .html("<!DOCTYPE html><title>OK</title><p>fine</p>"),
            "/empty-431": LocalHTTPServer.Response(status: 431, contentType: "", body: Data()),
            "/empty-431-nosniff": LocalHTTPServer.Response(
                status: 431, contentType: "", headers: ["X-Content-Type-Options": "nosniff"], body: Data()),
            "/html-500": LocalHTTPServer.Response(status: 500, contentType: "text/html", body: Data("<p>broken</p>".utf8)),
        ]
    }

    func testSuccessfulLoadRecordsItsStatus() {
        tab.loadURL(server.url("/ok"))
        XCTAssertTrue(waitUntil("status recorded") { self.tab.mainDocumentLoad?.httpStatus == 200 })
        XCTAssertNil(tab.mainDocumentLoad?.problem)
        XCTAssertEqual(tab.mainDocumentLoad?.url, server.url("/ok"))
    }

    /// The case an agent hit: an empty 431 that WebKit shows as an empty
    /// document, with nothing on screen to say why.
    func testEmptyErrorResponseIsAProblem() {
        tab.loadURL(server.url("/empty-431"))
        XCTAssertTrue(waitUntil("status recorded") { self.tab.mainDocumentLoad?.httpStatus == 431 })
        XCTAssertTrue(tab.mainDocumentLoad?.problem?.contains("HTTP 431 Request Header Fields Too Large") == true, "\(String(describing: tab.mainDocumentLoad))")
    }

    /// An error response WebKit cannot show becomes our own error page; the
    /// status must survive that page's own load.
    func testErrorStatusSurvivesOurErrorPage() {
        tab.loadURL(server.url("/empty-431-nosniff"))
        XCTAssertTrue(waitUntil("error page shown") {
            (try? self.callJS("return document.body ? document.body.innerText : ''") as? String)?.contains("HTTP 431") == true
        })
        settle(0.3)
        XCTAssertEqual(tab.mainDocumentLoad?.httpStatus, 431)
    }

    func testErrorPageFromTheServerIsAProblem() {
        tab.loadURL(server.url("/html-500"))
        XCTAssertTrue(waitUntil("status recorded") { self.tab.mainDocumentLoad?.httpStatus == 500 })
        XCTAssertNotNil(tab.mainDocumentLoad?.problem)
    }

    func testRefusedConnectionRecordsAnError() {
        tab.loadURL("http://127.0.0.1:9/")
        XCTAssertTrue(waitUntil("error recorded") { self.tab.mainDocumentLoad?.error != nil })
        XCTAssertNil(tab.mainDocumentLoad?.httpStatus)
        XCTAssertTrue(tab.mainDocumentLoad?.problem?.hasPrefix("the page did not load") == true)
    }

    func testEachLoadGetsANewSequence() {
        tab.loadURL(server.url("/ok"))
        XCTAssertTrue(waitUntil("first load") { self.tab.mainDocumentLoad != nil })
        let first = tab.mainDocumentLoad?.sequence
        tab.loadURL(server.url("/html-500"))
        XCTAssertTrue(waitUntil("second load") { self.tab.mainDocumentLoad?.httpStatus == 500 })
        XCTAssertNotEqual(tab.mainDocumentLoad?.sequence, first)
    }
}
