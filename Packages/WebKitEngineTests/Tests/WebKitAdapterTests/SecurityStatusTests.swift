import XCTest
@testable import WebKitAdapter

/// The site card's connection line comes from EngineTab.securityStatus();
/// a plain-http page must never be reported as having come over TLS.
@MainActor
final class SecurityStatusTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        ["/page": .html("<!DOCTYPE html><title>Plain</title><p>plain http</p>")]
    }

    func testNoStatusBeforeAnyPage() {
        XCTAssertNil(tab.securityStatus())
    }

    func testPlainHTTPPageIsNotASecureConnection() throws {
        loadAndWaitForCommit(server.url("/page"))
        let status = try XCTUnwrap(tab.securityStatus())
        XCTAssertFalse(status.isSecureConnection)
        XCTAssertFalse(status.hasCertificateError)
        XCTAssertNil(status.serverTrust)
    }

    func testNavigationReportsSecurityStateChanges() {
        loadAndWaitForCommit(server.url("/page"))
        XCTAssertGreaterThan(recorder.securityStateChanges, 0)
        XCTAssertFalse(tab.navigationState.isProvisional)
    }

    /// Mid-navigation, webView.url is already the new address while the
    /// trust still belongs to the old page, so nothing may be reported.
    func testNoStatusWhileProvisional() {
        loadAndWaitForCommit(server.url("/page"))
        tab.navigationState.isProvisional = true
        XCTAssertNil(tab.securityStatus())
    }
}
