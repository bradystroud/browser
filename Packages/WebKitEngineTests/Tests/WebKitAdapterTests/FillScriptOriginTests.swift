import XCTest
@testable import WebKitAdapter

/// Every script that writes a saved secret into a page -- a password, a card
/// number, an address -- is bound to the origin the user picked it for.
/// Evaluated against a document at any other origin it writes nothing.
final class FillScriptOriginTests: TwoOriginTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            // `__brwAutofillClassify` normally comes from the detection
            // script; here each field is simply classified by its name.
            "/form": .html("""
                <!DOCTYPE html><title>Form</title>
                <script>window.__brwAutofillClassify = function(el) { return el.name; };</script>
                <form>
                  <input type="text" name="ccNumber" id="cc">
                  <input type="text" name="streetAddress" id="street">
                  <input type="text" id="user">
                  <input type="password" id="pass">
                </form>
                """),
        ]
    }

    private func value(_ id: String) throws -> String? {
        try callJS("return document.getElementById(id).value;", arguments: ["id": id]) as? String
    }

    private func run(_ script: String) {
        tab.executeJavaScript(script)
        settle(0.3)
    }

    private func cardScript(for origin: WebOrigin) -> String {
        AutofillFillScript.fillCardScript(
            cardholderName: "A", cardNumber: "4111111111111111", expMonth: "01", expYear: "2030",
            combinedExpiry: "01/30", expectedOrigin: origin)
    }

    private func addressScript(for origin: WebOrigin) -> String {
        AutofillFillScript.fillAddressScript(
            fullName: "A", streetAddress: "1 Main St", addressLine2: "", city: "", state: "",
            postalCode: "", country: "", phone: "", email: "", expectedOrigin: origin)
    }

    func testCardFillsOnlyItsOwnOrigin() throws {
        loadAndWaitForCommit(server.url("/form"))
        run(cardScript(for: origin(of: other)))
        XCTAssertEqual(try value("cc"), "")
        run(cardScript(for: origin(of: server)))
        XCTAssertEqual(try value("cc"), "4111111111111111")
    }

    func testAddressFillsOnlyItsOwnOrigin() throws {
        loadAndWaitForCommit(server.url("/form"))
        run(addressScript(for: origin(of: other)))
        XCTAssertEqual(try value("street"), "")
        run(addressScript(for: origin(of: server)))
        XCTAssertEqual(try value("street"), "1 Main St")
    }

    func testPasswordFillsOnlyItsOwnOrigin() throws {
        loadAndWaitForCommit(server.url("/form"))
        run(AutofillScript.fillScript(username: "u", password: "p", expectedOrigin: origin(of: other)))
        XCTAssertEqual(try value("pass"), "")
        run(AutofillScript.fillScript(username: "u", password: "p", expectedOrigin: origin(of: server)))
        XCTAssertEqual(try value("pass"), "p")
    }
}
