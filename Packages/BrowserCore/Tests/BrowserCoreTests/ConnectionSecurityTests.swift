import XCTest
@testable import BrowserCore

final class ConnectionSecurityTests: XCTestCase {
    private let clean = ConnectionSecurity.EngineReport(isSecureConnection: true, hasCertificateError: false, hasInsecureContent: false)

    func testHTTPSWithCleanReportIsSecure() {
        XCTAssertEqual(ConnectionSecurity.classify(urlString: "https://example.com/a", report: clean), .secure)
    }

    func testInsecureContentOnHTTPSIsMixed() {
        var report = clean
        report.hasInsecureContent = true
        XCTAssertEqual(ConnectionSecurity.classify(urlString: "https://example.com", report: report), .mixedContent)
    }

    func testCertificateErrorWinsOverEverythingElse() {
        let report = ConnectionSecurity.EngineReport(isSecureConnection: true, hasCertificateError: true, hasInsecureContent: true)
        XCTAssertEqual(ConnectionSecurity.classify(urlString: "https://example.com", report: report), .certificateError)
    }

    func testHTTPSWithoutReportIsNeverClaimedSecure() {
        XCTAssertEqual(ConnectionSecurity.classify(urlString: "https://example.com", report: nil), .unverified)
        let notSecure = ConnectionSecurity.EngineReport(isSecureConnection: false, hasCertificateError: false, hasInsecureContent: false)
        XCTAssertEqual(ConnectionSecurity.classify(urlString: "https://example.com", report: notSecure), .unverified)
    }

    func testPlainHTTPIsNotSecureEvenWithAReport() {
        XCTAssertEqual(ConnectionSecurity.classify(urlString: "http://example.com", report: clean), .notSecure)
        XCTAssertEqual(ConnectionSecurity.classify(urlString: "HTTP://EXAMPLE.COM", report: nil), .notSecure)
    }

    func testLoopbackHTTPIsLocal() {
        for url in ["http://localhost:3000", "http://127.0.0.1/", "http://[::1]:8080/", "http://app.localhost/", "http://127.1.2.3"] {
            XCTAssertEqual(ConnectionSecurity.classify(urlString: url, report: nil), .local, url)
        }
    }

    func testLookalikeLoopbackHostsAreNotLocal() {
        for url in ["http://localhost.example.com", "http://127.0.0.1.example.com", "http://128.0.0.1"] {
            XCTAssertEqual(ConnectionSecurity.classify(urlString: url, report: nil), .notSecure, url)
        }
    }

    func testNonNetworkSchemesAreLocal() {
        for url in ["file:///Users/x/a.html", "about:blank", "data:text/html,hi", "view-source:https://example.com", ""] {
            XCTAssertEqual(ConnectionSecurity.classify(urlString: url, report: clean), .local, url)
        }
    }

    func testOnlyRiskyStatesWarn() {
        XCTAssertTrue(ConnectionSecurity.notSecure.isWarning)
        XCTAssertTrue(ConnectionSecurity.certificateError.isWarning)
        XCTAssertTrue(ConnectionSecurity.mixedContent.isWarning)
        XCTAssertFalse(ConnectionSecurity.secure.isWarning)
        XCTAssertFalse(ConnectionSecurity.local.isWarning)
    }
}
