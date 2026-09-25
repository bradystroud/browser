import XCTest
@testable import WebEngineCore

final class WebOriginTests: XCTestCase {
    func testDefaultPortIsNormalized() {
        XCTAssertEqual(WebOrigin(urlString: "https://a.com/login"), WebOrigin(urlString: "https://A.com:443/"))
        XCTAssertEqual(WebOrigin(urlString: "http://a.com")?.port, 80)
        XCTAssertEqual(WebOrigin(scheme: "https", host: "a.com", port: 0), WebOrigin(urlString: "https://a.com"))
    }

    func testSchemeAndPortDistinguishOrigins() {
        XCTAssertNotEqual(WebOrigin(urlString: "https://a.com"), WebOrigin(urlString: "http://a.com"))
        XCTAssertNotEqual(WebOrigin(urlString: "https://a.com"), WebOrigin(urlString: "https://a.com:8443"))
        XCTAssertNotEqual(WebOrigin(urlString: "https://a.com"), WebOrigin(urlString: "https://b.a.com"))
    }

    func testSerializationMatchesLocationOrigin() {
        XCTAssertEqual(WebOrigin(urlString: "https://a.com:443/x?y")?.serialized, "https://a.com")
        XCTAssertEqual(WebOrigin(urlString: "http://localhost:3000/")?.serialized, "http://localhost:3000")
        XCTAssertEqual(WebOrigin(urlString: "http://[::1]:8080/")?.serialized, "http://[::1]:8080")
    }

    func testNonHTTPURLsHaveNoOrigin() {
        for url in ["data:text/html,hi", "file:///etc/passwd", "about:blank", "javascript:alert(1)", "", "not a url", "ftp://a.com"] {
            XCTAssertNil(WebOrigin(urlString: url), url)
        }
    }

    func testBlobCarriesItsCreatorsOrigin() {
        XCTAssertEqual(WebOrigin(urlString: "blob:https://a.com/3f1c"), WebOrigin(urlString: "https://a.com"))
        XCTAssertNil(WebOrigin(urlString: "blob:null/3f1c"))
        XCTAssertNil(WebOrigin(urlString: "blob:blob:https://a.com/x"))
    }
}

final class CredentialScopeTests: XCTestCase {
    private func origin(_ string: String) -> WebOrigin { WebOrigin(urlString: string)! }

    func testExactOriginOnly() {
        let scope = CredentialScope.origin(origin("https://a.com"))
        XCTAssertTrue(scope.matches(origin("https://a.com/login")))
        XCTAssertTrue(scope.matches(origin("https://a.com:443")))
        XCTAssertFalse(scope.matches(origin("http://a.com")), "an https credential must never reach http")
        XCTAssertFalse(scope.matches(origin("https://a.com:8443")))
        XCTAssertFalse(scope.matches(origin("https://evil.a.com")))
    }

    func testHTTPCredentialStaysOnItsPort() {
        let scope = CredentialScope.origin(origin("http://intranet:8080"))
        XCTAssertTrue(scope.matches(origin("http://intranet:8080/")))
        XCTAssertFalse(scope.matches(origin("http://intranet")))
        XCTAssertFalse(scope.matches(origin("https://intranet:8080")))
    }

    func testLegacyHostOnlyMatchesDefaultHTTPS() {
        let scope = CredentialScope.legacyHost("a.com")
        XCTAssertTrue(scope.matches(origin("https://a.com")))
        XCTAssertTrue(scope.matches(origin("https://A.com:443")))
        XCTAssertFalse(scope.matches(origin("http://a.com")))
        XCTAssertFalse(scope.matches(origin("https://a.com:8443")))
        XCTAssertFalse(scope.matches(origin("https://b.com")))
    }

    func testLegacyLoopbackKeepsWorkingOnAnyPort() {
        let scope = CredentialScope.legacyHost("localhost")
        XCTAssertTrue(scope.matches(origin("http://localhost:3000")))
        XCTAssertTrue(scope.matches(origin("https://localhost")))
        XCTAssertFalse(CredentialScope.legacyHost("127.0.0.1").matches(origin("http://localhost:3000")))
    }

    func testExactBeatsLegacy() {
        let candidates: [CredentialScope] = [.legacyHost("a.com"), .origin(origin("https://a.com")), .origin(origin("http://a.com"))]
        XCTAssertEqual(CredentialScope.bestMatch(for: origin("https://a.com"), in: candidates) { $0 }, .origin(origin("https://a.com")))
        XCTAssertEqual(CredentialScope.bestMatch(for: origin("http://a.com"), in: candidates) { $0 }, .origin(origin("http://a.com")))
        XCTAssertNil(CredentialScope.bestMatch(for: origin("http://a.com:81"), in: candidates) { $0 })
    }
}

final class PageMessagePolicyTests: XCTestCase {
    private let tab = PageMessageTabState(engineURL: "https://bank.example/login", isShowingStartPage: false)

    func testMainFrameMessageGetsTheNativeOrigin() {
        let source = PageMessageSource(isMainFrame: true, frameURL: "https://bank.example/login")
        XCTAssertEqual(PageMessagePolicy.evaluate(type: "passwordFormSubmit", source: source, tab: tab),
                       .allow(origin: WebOrigin(urlString: "https://bank.example")))
    }

    func testSubframeIsRejectedForEveryType() {
        let source = PageMessageSource(isMainFrame: false, frameURL: "https://bank.example/frame")
        for type in PageMessagePolicy.rules.keys.sorted() + ["somethingNew"] {
            guard case .reject = PageMessagePolicy.evaluate(type: type, source: source, tab: tab) else {
                return XCTFail("\(type) accepted from a subframe")
            }
        }
    }

    func testEveryRegisteredTypeIsMainFrameOnly() {
        XCTAssertTrue(PageMessagePolicy.rules.values.allSatisfy { $0 == .mainFrame || $0 == .startPage })
        XCTAssertEqual(PageMessagePolicy.rule(forType: "unknown"), .mainFrame)
    }

    func testOriginMustAgreeWithTheTab() {
        // A document on another origin that is still live while the tab has
        // already moved on (or not yet committed) cannot speak for the tab.
        let source = PageMessageSource(isMainFrame: true, frameURL: "https://evil.example/")
        guard case .reject = PageMessagePolicy.evaluate(type: "passwordFormSubmit", source: source, tab: tab) else {
            return XCTFail("origin mismatch accepted")
        }
    }

    func testEngineOriginMustAgreeWithFrameURL() {
        let source = PageMessageSource(isMainFrame: true, frameURL: "https://bank.example/login",
                                       origin: WebOrigin(urlString: "https://evil.example"))
        guard case .reject = PageMessagePolicy.evaluate(type: "passwordFormSubmit", source: source, tab: tab) else {
            return XCTFail("inherited origin accepted")
        }
    }

    func testOpaqueOriginIsRejected() {
        let source = PageMessageSource(isMainFrame: true, frameURL: "https://bank.example/login", origin: nil)
        guard case .reject = PageMessagePolicy.evaluate(type: "notificationShow", source: source, tab: tab) else {
            return XCTFail("opaque origin accepted")
        }
    }

    func testHTTPPageCannotSpeakForHTTPSTab() {
        let source = PageMessageSource(isMainFrame: true, frameURL: "http://bank.example/login")
        guard case .reject = PageMessagePolicy.evaluate(type: "passwordFormSubmit", source: source, tab: tab) else {
            return XCTFail("scheme mismatch accepted")
        }
    }

    func testStartPageMessageOnlyFromTheStartPageDocument() {
        let startURL = "data:text/html;charset=utf-8;base64,PGgxPmhpPC9oMT4="
        let startTab = PageMessageTabState(engineURL: startURL, isShowingStartPage: true)
        XCTAssertEqual(PageMessagePolicy.evaluate(type: "openStartPageSettings",
                                                  source: PageMessageSource(isMainFrame: true, frameURL: startURL), tab: startTab),
                       .allow(origin: nil))

        let rejected: [(PageMessageSource, PageMessageTabState)] = [
            (PageMessageSource(isMainFrame: true, frameURL: "https://bank.example/login"), tab),
            (PageMessageSource(isMainFrame: true, frameURL: "data:text/html,other"), startTab),
            (PageMessageSource(isMainFrame: false, frameURL: startURL), startTab),
            (PageMessageSource(isMainFrame: true, frameURL: startURL),
             PageMessageTabState(engineURL: startURL, isShowingStartPage: false)),
        ]
        for (source, tabState) in rejected {
            guard case .reject = PageMessagePolicy.evaluate(type: "openStartPageSettings", source: source, tab: tabState) else {
                return XCTFail("start-page message accepted from \(source)")
            }
        }
    }

    func testOrdinaryMessagesAreRejectedOnTheStartPage() {
        let startURL = "data:text/html,x"
        let startTab = PageMessageTabState(engineURL: startURL, isShowingStartPage: true)
        guard case .reject = PageMessagePolicy.evaluate(type: "passwordFormSubmit",
                                                        source: PageMessageSource(isMainFrame: true, frameURL: startURL),
                                                        tab: startTab) else {
            return XCTFail("password message accepted from the start page")
        }
    }
}

final class PopupTargetPolicyTests: XCTestCase {
    func testOrdinaryTargets() {
        XCTAssertTrue(PopupTargetPolicy.isAllowed(targetURL: "https://a.com/x", openerFrameURL: "https://b.com/"))
        XCTAssertTrue(PopupTargetPolicy.isAllowed(targetURL: "http://a.com/x", openerFrameURL: "https://b.com/"))
        XCTAssertTrue(PopupTargetPolicy.isAllowed(targetURL: "about:blank", openerFrameURL: "https://b.com/"))
        XCTAssertTrue(PopupTargetPolicy.isAllowed(targetURL: "", openerFrameURL: "https://b.com/"))
    }

    func testDangerousSchemesAreRefused() {
        for url in ["data:text/html,<script>alert(1)</script>", "DATA:text/html,x", " data:text/html,x",
                    "file:///etc/passwd", "javascript:alert(1)", "about:srcdoc", "chrome://settings",
                    "view-source:https://a.com", "filesystem:https://a.com/temporary/x"] {
            XCTAssertFalse(PopupTargetPolicy.isAllowed(targetURL: url, openerFrameURL: "https://a.com/"), url)
        }
    }

    func testBlobOnlyFromItsOwnOrigin() {
        XCTAssertTrue(PopupTargetPolicy.isAllowed(targetURL: "blob:https://a.com/1234", openerFrameURL: "https://a.com/page"))
        XCTAssertFalse(PopupTargetPolicy.isAllowed(targetURL: "blob:https://a.com/1234", openerFrameURL: "https://evil.com/"))
        XCTAssertFalse(PopupTargetPolicy.isAllowed(targetURL: "blob:https://a.com/1234", openerFrameURL: "http://a.com/"))
        XCTAssertFalse(PopupTargetPolicy.isAllowed(targetURL: "blob:null/1234", openerFrameURL: "https://a.com/"))
        XCTAssertFalse(PopupTargetPolicy.isAllowed(targetURL: "blob:https://a.com/1234", openerFrameURL: "about:blank"))
    }
}
