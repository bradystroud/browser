import XCTest
@testable import WebKitAdapter

final class DownloadTests: WebKitTabTestCase {
    private var downloadDirectory: URL!

    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/attach": LocalHTTPServer.Response(
                contentType: "text/plain",
                headers: ["Content-Disposition": "attachment; filename=\"report.txt\""],
                body: Data("downloaded body".utf8)),
            "/inline": LocalHTTPServer.Response(
                contentType: "text/plain",
                headers: ["Content-Disposition": "inline; filename=\"shown.txt\""],
                body: Data("inline body".utf8)),
            "/empty-404": LocalHTTPServer.Response(
                status: 404, contentType: "", headers: ["X-Content-Type-Options": "nosniff"], body: Data()),
            "/attach-500": LocalHTTPServer.Response(
                status: 500, contentType: "text/plain",
                headers: ["Content-Disposition": "attachment; filename=\"error.txt\""],
                body: Data("error body".utf8)),
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        downloadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WebKitAdapterTests-downloads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        WebKitEngine.setDownloadDirectory(downloadDirectory.path)
    }

    override func tearDownWithError() throws {
        WebKitEngine.setDownloadDirectory("")
        if let downloadDirectory { try? FileManager.default.removeItem(at: downloadDirectory) }
        try super.tearDownWithError()
    }

    func testAttachmentBecomesDownloadIntoConfiguredDirectory() throws {
        tab.loadURL(server.url("/attach"))
        waitUntil("download finished") { recorder.firstIndex(of: "downloadEnd") != nil }

        let download = try XCTUnwrap(recorder.downloads.values.first)
        XCTAssertEqual(recorder.downloads.count, 1)
        XCTAssertTrue(download.isComplete, "\(download)")
        XCTAssertEqual(download.suggestedName, "report.txt")
        XCTAssertEqual(download.url, server.url("/attach"))
        let destination = URL(fileURLWithPath: download.destinationPath)
        XCTAssertEqual(destination.deletingLastPathComponent().standardizedFileURL.path,
                       downloadDirectory.standardizedFileURL.path)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "downloaded body")
        XCTAssertTrue(recorder.events(named: "commit").isEmpty, "a download is not a visit: \(recorder.events)")
    }

    func testSecondDownloadOfSameNameGetsNumberedPath() throws {
        tab.loadURL(server.url("/attach"))
        waitUntil("first download finished") { recorder.events(named: "downloadEnd").count == 1 }
        tab.loadURL(server.url("/attach"))
        waitUntil("second download finished") { recorder.events(named: "downloadEnd").count == 2 }

        let names = recorder.downloads.values.map { URL(fileURLWithPath: $0.destinationPath).lastPathComponent }.sorted()
        XCTAssertEqual(names, ["report (1).txt", "report.txt"])
        XCTAssertTrue(recorder.downloads.values.allSatisfy(\.isComplete))
    }

    func testInlineDispositionRenders() throws {
        loadAndWaitForCommit(server.url("/inline"))
        let text = try callJS("return document.body.innerText") as? String
        XCTAssertEqual(text?.trimmingCharacters(in: .whitespacesAndNewlines), "inline body")
        settle(0.2)
        XCTAssertTrue(recorder.downloads.isEmpty, "inline content must render, not download: \(recorder.events)")
    }

    /// An HTTP error with nothing WebKit can show is an error page at that
    /// URL, never an empty file in Downloads with the tab left behind.
    func testEmptyErrorResponseShowsErrorPageNotDownload() throws {
        tab.loadURL(server.url("/empty-404"))
        waitUntil("error page shown") {
            (try? self.callJS("return document.body ? document.body.innerText : ''") as? String)?.contains("HTTP 404") == true
        }
        let href = try callJS("return location.href") as? String
        XCTAssertEqual(href, server.url("/empty-404"))
        settle(0.2)
        XCTAssertTrue(recorder.downloads.isEmpty, "an empty error response must not download: \(recorder.events)")
    }

    func testErrorResponseThatIsAnAttachmentStillDownloads() throws {
        tab.loadURL(server.url("/attach-500"))
        waitUntil("download finished") { recorder.firstIndex(of: "downloadEnd") != nil }
        XCTAssertEqual(recorder.downloads.values.first?.suggestedName, "error.txt")
    }

    // MARK: - Policy and path rules (no web view needed)

    func testContentDispositionParsing() {
        func response(_ header: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.com/f")!, statusCode: 200, httpVersion: "HTTP/1.1",
                            headerFields: header.map { ["Content-Disposition": $0] } ?? [:])!
        }
        XCTAssertTrue(WebKitDownloadPolicy.isAttachment(response("attachment")))
        XCTAssertTrue(WebKitDownloadPolicy.isAttachment(response("attachment; filename=\"a.pdf\"")))
        XCTAssertTrue(WebKitDownloadPolicy.isAttachment(response("ATTACHMENT;filename=a.pdf")))
        XCTAssertTrue(WebKitDownloadPolicy.isAttachment(response("something-unknown; filename=a")), "RFC 6266: unknown types are attachments")
        XCTAssertFalse(WebKitDownloadPolicy.isAttachment(response("inline")))
        XCTAssertFalse(WebKitDownloadPolicy.isAttachment(response("inline; filename=\"a.pdf\"")))
        XCTAssertFalse(WebKitDownloadPolicy.isAttachment(response("filename=a.pdf")))
        XCTAssertFalse(WebKitDownloadPolicy.isAttachment(response("")))
        XCTAssertFalse(WebKitDownloadPolicy.isAttachment(response(nil)))
        XCTAssertFalse(WebKitDownloadPolicy.isAttachment(URLResponse(url: URL(string: "file:///x")!, mimeType: nil,
                                                                     expectedContentLength: 0, textEncodingName: nil)))
    }

    func testUniqueDestinationNumbering() {
        let directory = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)
        func unique(_ name: String, taken: Set<String>) -> String {
            WebKitDownloadPolicy.uniqueDestination(in: directory, suggestedName: name) { taken.contains($0.lastPathComponent) }
                .lastPathComponent
        }
        XCTAssertEqual(unique("a.txt", taken: []), "a.txt")
        XCTAssertEqual(unique("a.txt", taken: ["a.txt"]), "a (1).txt")
        XCTAssertEqual(unique("a.txt", taken: ["a.txt", "a (1).txt"]), "a (2).txt")
        XCTAssertEqual(unique("a.txt", taken: ["a.txt", "a (1).txt", "a (2).txt", "a (3).txt"]), "a (4).txt")
        XCTAssertEqual(unique("README", taken: ["README"]), "README (1)")
        XCTAssertEqual(unique("archive.tar.gz", taken: ["archive.tar.gz"]), "archive.tar (1).gz")
        XCTAssertEqual(WebKitDownloadPolicy.uniqueDestination(in: directory, suggestedName: "a.txt") { _ in false },
                       directory.appendingPathComponent("a.txt"))
    }
}
