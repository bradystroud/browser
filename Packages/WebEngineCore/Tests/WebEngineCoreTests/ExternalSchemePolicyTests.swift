import XCTest
@testable import WebEngineCore

final class ExternalSchemePolicyTests: XCTestCase {
    func testMailAndPhoneOpenDirectlyOnAClick() {
        for scheme in ["mailto", "tel", "MAILTO"] {
            XCTAssertEqual(ExternalSchemePolicy.decide(scheme: scheme, userClicked: true, isMainFrame: true), .openDirectly, scheme)
            XCTAssertEqual(ExternalSchemePolicy.decide(scheme: scheme, userClicked: true, isMainFrame: false), .openDirectly, scheme)
        }
    }

    func testOtherAppsAreAskedAboutEvenOnAClick() {
        for scheme in ["zoommtg", "facetime", "smb", "slack", "afp", "vnc", "ssh", "x-apple.systempreferences"] {
            XCTAssertEqual(ExternalSchemePolicy.decide(scheme: scheme, userClicked: true, isMainFrame: true), .askFirst, scheme)
            XCTAssertEqual(ExternalSchemePolicy.decide(scheme: scheme, userClicked: true, isMainFrame: false), .askFirst, scheme)
        }
    }

    func testMailWithoutAClickIsAskedAbout() {
        XCTAssertEqual(ExternalSchemePolicy.decide(scheme: "mailto", userClicked: false, isMainFrame: true), .askFirst)
    }

    func testMainFrameRedirectIsAskedAbout() {
        XCTAssertEqual(ExternalSchemePolicy.decide(scheme: "zoommtg", userClicked: false, isMainFrame: true), .askFirst)
    }

    func testSubframeWithoutAClickCannotEvenAsk() {
        for scheme in ["zoommtg", "mailto", "tel", "smb"] {
            XCTAssertEqual(ExternalSchemePolicy.decide(scheme: scheme, userClicked: false, isMainFrame: false), .ignore, scheme)
        }
    }
}
