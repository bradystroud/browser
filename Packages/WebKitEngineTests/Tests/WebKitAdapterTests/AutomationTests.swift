import AppKit
import XCTest
@testable import WebKitAdapter

/// Agent control on the WebKit engine: input must reach a page as trusted
/// events the way the `browser page` commands rely on, dialogs must not
/// block it, and capture must produce real images.
final class AutomationTests: WebKitTabTestCase {
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/form": .html("""
                <!DOCTYPE html><title>Form</title>
                <style>body{margin:0} button,input{position:absolute;left:20px;width:200px;height:30px}</style>
                <button id="b" style="top:20px" onclick="document.title='clicked ' + event.detail">Go</button>
                <form id="f" onsubmit="event.preventDefault(); document.title='submitted ' + this.q.value">
                  <input id="q" name="q" style="top:80px" oninput="window.inputs = (window.inputs || 0) + 1">
                </form>
                <input id="other" style="top:140px">
                <button id="ask" style="top:200px" onclick="document.title='confirm ' + confirm('sure?') + ' ' + prompt('name?', 'x')">Ask</button>
                <iframe id="fr" src="/inner" style="position:absolute;left:20px;top:260px;width:300px;height:80px;border:0"></iframe>
                <script>
                  addEventListener('click', e => window.lastClickTrusted = e.isTrusted, true);
                  addEventListener('keydown', e => window.lastKeyTrusted = e.isTrusted, true);
                </script>
                """),
            "/inner": .html("""
                <!DOCTYPE html><style>body{margin:0}</style><input id="inner" style="width:200px;height:30px">
                """),
            "/tall": .html("""
                <!DOCTYPE html><title>Tall</title>
                <style>body{margin:0} div{height:400px} #top{background:#f00} #mid{background:#0f0} #end{background:#00f}</style>
                <div id="top"></div><div id="mid"></div><div id="end"></div>
                """),
        ]
    }

    private var automation: EngineTabAutomation!

    override func setUpWithError() throws {
        try super.setUpWithError()
        loadAndWaitForCommit(server.url("/form"))
        waitUntil("form ready") { (try? callJS("return !!document.getElementById('other')")) as? Bool == true }
        automation = try XCTUnwrap(tab.automation)
    }

    private func perform<T>(_ description: String, _ action: (@escaping (Result<T, EngineAutomationError>) -> Void) -> Void,
                            file: StaticString = #filePath, line: UInt = #line) -> T? {
        var outcome: Result<T, EngineAutomationError>?
        action { outcome = $0 }
        waitUntil(description, file: file, line: line) { outcome != nil }
        switch outcome {
        case .success(let value): return value
        case .failure(let error):
            XCTFail("\(description) failed: \(error)", file: file, line: line)
            return nil
        case nil: return nil
        }
    }

    private func title() -> String? { try? callJS("return document.title") as? String }

    func testClickReachesTheElementUnderThePointAsATrustedEvent() {
        perform("click") { automation.click(at: CGPoint(x: 60, y: 35), clickCount: 1, completion: $0) }
        XCTAssertEqual(title(), "clicked 1")
        XCTAssertEqual(try callJS("return window.lastClickTrusted") as? Bool, true)
        XCTAssertFalse(NSApp.isActive)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testDoubleClickCountsTwo() {
        perform("double click") { automation.click(at: CGPoint(x: 60, y: 35), clickCount: 2, completion: $0) }
        XCTAssertEqual(title(), "clicked 2")
    }

    func testDialogHandlerAnswersInsteadOfShowingThem() {
        var seen: [String] = []
        automation.dialogHandler = { dialog in
            switch dialog {
            case .confirm(let message): seen.append("confirm:\(message)"); return .accept(text: nil)
            case .prompt(let message, _): seen.append("prompt:\(message)"); return .accept(text: "agent")
            default: return .dismiss
            }
        }
        perform("click ask") { automation.click(at: CGPoint(x: 60, y: 215), clickCount: 1, completion: $0) }
        waitUntil("answered") { title() == "confirm true agent" }
        XCTAssertEqual(seen, ["confirm:sure?", "prompt:name?"])
        XCTAssertNil(window.attachedSheet)
    }

    func testTypingReachesASameOriginFrame() {
        waitUntil("frame ready") { (try? callJS("return !!document.getElementById('fr').contentDocument?.getElementById('inner')")) as? Bool == true }
        perform("click frame field") { automation.click(at: CGPoint(x: 60, y: 275), clickCount: 1, completion: $0) }
        perform("type") { automation.insertText("framed", completion: $0) }
        XCTAssertEqual(try callJS("return document.getElementById('fr').contentDocument.getElementById('inner').value") as? String, "framed")
    }

    func testUnhandledKeysStayOutOfTheResponderChain() throws {
        final class Spy: NSResponder {
            var commands: [String] = []
            override func doCommand(by selector: Selector) { commands.append(NSStringFromSelector(selector)) }
            override func cancelOperation(_ sender: Any?) { commands.append("cancelOperation:") }
        }
        let spy = Spy()
        spy.nextResponder = tab.webView.nextResponder
        tab.webView.nextResponder = spy
        defer { tab.webView.nextResponder = spy.nextResponder }
        let escape = try XCTUnwrap(EngineAutomationKey(name: "Escape"))
        perform("escape") { automation.pressKey(escape, modifiers: [], completion: $0) }
        let w = try XCTUnwrap(EngineAutomationKey(name: "w"))
        perform("cmd-w") { automation.pressKey(w, modifiers: [.command], completion: $0) }
        settle(0.2)
        XCTAssertEqual(spy.commands, [])
        XCTAssertTrue(tab.webView.nextResponder === spy)
        XCTAssertEqual(try callJS("return window.lastKeyTrusted") as? Bool, true)
    }

    func testClickFocusesAndTextGoesInWithInputEvents() {
        perform("click field") { automation.click(at: CGPoint(x: 60, y: 95), clickCount: 1, completion: $0) }
        XCTAssertEqual(try callJS("return document.activeElement.id") as? String, "q")
        perform("type") { automation.insertText("wheel", completion: $0) }
        XCTAssertEqual(try callJS("return document.getElementById('q').value") as? String, "wheel")
        XCTAssertGreaterThanOrEqual(try callJS("return window.inputs") as? Int ?? 0, 1)
    }

    func testBackspaceDeletesAndEnterSubmits() throws {
        perform("click field") { automation.click(at: CGPoint(x: 60, y: 95), clickCount: 1, completion: $0) }
        perform("type") { automation.insertText("hubs", completion: $0) }
        let backspace = try XCTUnwrap(EngineAutomationKey(name: "Backspace"))
        perform("backspace") { automation.pressKey(backspace, modifiers: [], completion: $0) }
        let enter = try XCTUnwrap(EngineAutomationKey(name: "Enter"))
        perform("enter") { automation.pressKey(enter, modifiers: [], completion: $0) }
        XCTAssertEqual(title(), "submitted hub")
    }

    func testTabMovesFocusAndCharacterKeysType() throws {
        perform("click field") { automation.click(at: CGPoint(x: 60, y: 95), clickCount: 1, completion: $0) }
        let tabKey = try XCTUnwrap(EngineAutomationKey(name: "Tab"))
        perform("tab") { automation.pressKey(tabKey, modifiers: [], completion: $0) }
        XCTAssertEqual(try callJS("return document.activeElement.id") as? String, "other")
        let x = try XCTUnwrap(EngineAutomationKey(name: "x"))
        perform("x") { automation.pressKey(x, modifiers: [], completion: $0) }
        XCTAssertEqual(try callJS("return document.getElementById('other').value") as? String, "x")
    }

    func testEvaluateReturnsJSONAndReportsThrows() {
        let value = perform("evaluate") { automation.evaluate("({a: 1, b: [true, 'x']})", completion: $0) } ?? nil
        let object = value as? [String: Any]
        XCTAssertEqual(object?["a"] as? Int, 1)
        XCTAssertEqual((object?["b"] as? [Any])?.count, 2)

        var failure: EngineAutomationError?
        automation.evaluate("nope()") { if case .failure(let error) = $0 { failure = error } }
        waitUntil("evaluate failure") { failure != nil }
        XCTAssertTrue(failure?.message.contains("nope") ?? false, "\(String(describing: failure))")
    }

    func testScreenshotIsAPNGAtDeviceResolution() throws {
        let png = try XCTUnwrap(perform("screenshot") { automation.screenshot(fullPage: false, completion: $0) })
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertGreaterThanOrEqual(image.pixelsWide, Int(tab.webView.bounds.width))
        XCTAssertEqual(png.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testFullPageScreenshotStitchesTheWholeDocumentAndRestoresScroll() throws {
        loadAndWaitForCommit(server.url("/tall"))
        waitUntil("tall ready") { (try? callJS("return document.title")) as? String == "Tall" }
        automation = try XCTUnwrap(tab.automation)
        _ = try callJS("scrollTo(0, 100)")
        let visible = try XCTUnwrap(perform("visible") { automation.screenshot(fullPage: false, completion: $0) })
        let full = try XCTUnwrap(perform("full page") { automation.screenshot(fullPage: true, completion: $0) })
        let visibleImage = try XCTUnwrap(NSBitmapImageRep(data: visible))
        let fullImage = try XCTUnwrap(NSBitmapImageRep(data: full))
        let scale = Double(visibleImage.pixelsWide) / tab.webView.bounds.width
        XCTAssertEqual(fullImage.pixelsWide, visibleImage.pixelsWide)
        XCTAssertEqual(Double(fullImage.pixelsHigh), 1200 * scale, accuracy: 2 * scale)
        // The last strip is blue, the first red, so the page was really scrolled.
        let bottom = try XCTUnwrap(fullImage.colorAt(x: fullImage.pixelsWide / 2, y: fullImage.pixelsHigh - 2))
        let top = try XCTUnwrap(fullImage.colorAt(x: fullImage.pixelsWide / 2, y: 2))
        XCTAssertGreaterThan(bottom.blueComponent, 0.9)
        XCTAssertLessThan(bottom.redComponent, 0.1)
        XCTAssertGreaterThan(top.redComponent, 0.9)
        XCTAssertEqual(try callJS("return scrollY") as? Int, 100)
    }

    func testOptionChordTypesTheLayoutsCharacter() throws {
        perform("click field") { automation.click(at: CGPoint(x: 60, y: 95), clickCount: 1, completion: $0) }
        let two = try XCTUnwrap(EngineAutomationKey(name: "2"))
        perform("alt-2") { automation.pressKey(two, modifiers: [.alt], completion: $0) }
        let expected = MacKeyboardLayout.typedText(for: "2", shift: false, option: true)
        XCTAssertEqual(try callJS("return document.getElementById('q').value") as? String, expected)
        // A US or Australian layout types the trademark sign there.
        if MacKeyboardLayout.characters(keyCode: 19, shift: false, option: false) == "2", expected != "2" {
            XCTAssertEqual(expected, "™")
        }
    }

    func testScreencastDeliversFramesUntilStopped() {
        var frames: [TimeInterval] = []
        perform("start") { automation.startScreencast(quality: 70, onFrame: { _, time in frames.append(time) }, completion: $0) }
        waitUntil("three frames") { frames.count >= 3 }
        automation.stopScreencast()
        let stoppedAt = frames.count
        settle(0.4)
        XCTAssertLessThanOrEqual(frames.count, stoppedAt + 1)
        XCTAssertEqual(frames, frames.sorted())
    }
}
