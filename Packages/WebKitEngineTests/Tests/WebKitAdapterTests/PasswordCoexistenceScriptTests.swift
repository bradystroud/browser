import XCTest
@testable import WebKitAdapter

/// The page-side halves of living with a password-manager extension, in a
/// real WKWebView: the saved password never lands in a new-password field,
/// and the email script says which fields are a sign-in's user name (where
/// such an extension shows its list) and which are not.
final class PasswordCoexistenceScriptTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/signup": .html("""
                <!DOCTYPE html><title>Sign up</title>
                <form><input type="email" id="user"><input type="password" id="new" autocomplete="new-password"></form>
                """),
            "/change": .html("""
                <!DOCTYPE html><title>Change</title>
                <form>
                  <input type="text" id="user" autocomplete="username">
                  <input type="password" id="new" autocomplete="new-password">
                  <input type="password" id="current" autocomplete="current-password">
                </form>
                """),
            "/fields": .html("""
                <!DOCTYPE html><title>Fields</title>
                <input type="email" name="loginfmt" id="microsoft">
                <input type="text" id="google" autocomplete="username webauthn">
                <label for="labelled">User name or email</label><input type="email" id="labelled">
                <form><input type="email" id="newsletter" name="newsletter_email" placeholder="Your email"></form>
                """),
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        recorder.onPageMessage = { [weak self] _, requestId in
            DispatchQueue.main.async {
                self?.tab.respondToPageMessage(requestId: requestId, success: true, response: "{}")
            }
        }
    }

    private func value(_ id: String) throws -> String? {
        try callJS("return document.getElementById(id).value;", arguments: ["id": id]) as? String
    }

    private func fill(_ path: String) {
        let origin = try! XCTUnwrap(WebOrigin(urlString: server.url(path)))
        tab.executeJavaScript(AutofillScript.fillScript(username: "me@example.com", password: "saved", expectedOrigin: origin))
        settle(0.3)
    }

    func testSavedPasswordNeverFillsANewPasswordField() throws {
        loadAndWaitForCommit(server.url("/signup"))
        fill("/signup")
        XCTAssertEqual(try value("new"), "", "a sign-up's new password is not the saved one")
        XCTAssertEqual(try value("user"), "", "and nothing is filled when there is nowhere for the password")
    }

    func testChangePasswordFormGetsOnlyTheCurrentPassword() throws {
        loadAndWaitForCommit(server.url("/change"))
        fill("/change")
        XCTAssertEqual(try value("current"), "saved")
        XCTAssertEqual(try value("new"), "")
    }

    private func focusReport(_ id: String) throws -> String {
        let before = recorder.pageMessages.count
        _ = try callJS("document.getElementById(id).dispatchEvent(new FocusEvent('focusin', { bubbles: true })); return true;",
                       arguments: ["id": id])
        waitUntil("focus message for \(id)") {
            recorder.pageMessages.dropFirst(before).contains { $0.request.contains("\"type\":\"emailFieldFocused\"") }
        }
        return try XCTUnwrap(recorder.pageMessages.dropFirst(before).first { $0.request.contains("\"type\":\"emailFieldFocused\"") }?.request)
    }

    func testEmailScriptTellsSignInFieldsFromOthers() throws {
        loadAndWaitForCommit(server.url("/fields"))
        tab.executeJavaScript(EmailFieldDetectionScript.source)
        settle(0.2)
        XCTAssertTrue(try focusReport("microsoft").contains("\"usernameLike\":true"))
        XCTAssertTrue(try focusReport("google").contains("\"usernameLike\":true"))
        XCTAssertTrue(try focusReport("labelled").contains("\"usernameLike\":true"))
        let newsletter = try focusReport("newsletter")
        XCTAssertTrue(newsletter.contains("\"usernameLike\":false"), newsletter)
        XCTAssertTrue(newsletter.contains("\"hasPasswordField\":false"), newsletter)
    }
}
