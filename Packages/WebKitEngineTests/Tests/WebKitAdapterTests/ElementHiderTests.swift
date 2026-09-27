import XCTest
@testable import WebKitAdapter

/// The element hider on a real WKWebView: the site stylesheet is in force
/// before the page's own first script runs, and the picker reports a
/// selector that finds exactly the element that was clicked.
final class ElementHiderTests: WebKitTabTestCase {
    /// The inline script sits right after the element, so what it records
    /// is the element's style at parse time -- before any load event, and
    /// before anything the adapter could inject once the page has committed.
    override func routes() -> [String: LocalHTTPServer.Response] {
        [
            "/page": .html("""
                <!DOCTYPE html><html><head><title>Hider</title></head><body>
                <div id="ad">advert</div>
                <script>window.adDisplayAtParse = getComputedStyle(document.getElementById('ad')).display;</script>
                <div id="keep">content</div>
                <ul class="list">
                  <li style="height:40px">one</li>
                  <li style="height:40px" class="css-1x2y3z">two</li>
                  <li style="height:40px">three</li>
                </ul>
                <section><div style="height:30px" class="css-9q8w7e">anonymous</div></section>
                </body></html>
                """),
        ]
    }

    private let site = "127.0.0.1"
    private let adSheet = "#ad { display: none !important; }"

    private func display(of id: String) throws -> String? {
        try callJS("return getComputedStyle(document.getElementById(id)).display", arguments: ["id": id]) as? String
    }

    func testSheetIsInForceBeforeThePageParsesPastTheElement() throws {
        tab.setSiteStyleSheets([site: adSheet])
        loadAndWaitForCommit(server.url("/page"))
        waitUntil("page scripts ran") { ((try? callJS("return window.adDisplayAtParse || null")) as? String) != nil }

        XCTAssertEqual(try callJS("return window.adDisplayAtParse") as? String, "none")
        XCTAssertEqual(try display(of: "keep"), "block")
    }

    func testSheetForAnotherSiteDoesNotApply() throws {
        tab.setSiteStyleSheets(["example.com": adSheet])
        loadAndWaitForCommit(server.url("/page"))
        waitUntil("page scripts ran") { ((try? callJS("return window.adDisplayAtParse || null")) as? String) != nil }

        XCTAssertEqual(try callJS("return window.adDisplayAtParse") as? String, "block")
    }

    func testChangingSheetsUpdatesTheCurrentDocumentAndLaterOnes() throws {
        loadAndWaitForCommit(server.url("/page"))
        waitUntil("page loaded") { (try? display(of: "ad")) == "block" }

        tab.setSiteStyleSheets([site: adSheet])
        XCTAssertTrue(waitUntil("hidden in place") { (try? display(of: "ad")) == "none" })

        tab.setSiteStyleSheets([:])
        XCTAssertTrue(waitUntil("restored in place") { (try? display(of: "ad")) == "block" })

        tab.reload()
        settle(0.5)
        waitUntil("reloaded page scripts ran") { ((try? callJS("return window.adDisplayAtParse || null")) as? String) != nil }
        XCTAssertEqual(try callJS("return window.adDisplayAtParse") as? String, "block")
    }

    /// Other features' document-start scripts survive the sheet being
    /// swapped in and out -- WKUserContentController can only be rebuilt
    /// whole.
    func testSwappingSheetsKeepsTheCefQueryShim() throws {
        tab.setSiteStyleSheets([site: adSheet])
        tab.setSiteStyleSheets([site: "#keep { display: none !important; }"])
        loadAndWaitForCommit(server.url("/page"))
        XCTAssertEqual(try callJS("return typeof window.cefQuery") as? String, "function")
        XCTAssertTrue(waitUntil("second sheet applied") { (try? display(of: "keep")) == "none" })
        XCTAssertEqual(try display(of: "ad"), "block")
    }

    // MARK: - Picker

    private func pick(_ js: String) throws -> [String: Any] {
        let before = recorder.pageMessages.count
        _ = try callJS("""
            const el = \(js);
            const r = el.getBoundingClientRect();
            const x = r.left + r.width / 2, y = r.top + r.height / 2;
            window.dispatchEvent(new MouseEvent('mousemove', { clientX: x, clientY: y, bubbles: true }));
            window.dispatchEvent(new PointerEvent('pointerdown', { clientX: x, clientY: y, button: 0, bubbles: true }));
            """)
        waitUntil("picked message") { recorder.pageMessages.count > before }
        let request = try XCTUnwrap(recorder.pageMessages.last?.request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
    }

    private func matchCount(_ selector: String, is js: String) throws -> Bool {
        try callJS("const all = document.querySelectorAll(sel); return all.length === 1 && all[0] === \(js);",
                   arguments: ["sel": selector]) as? Bool ?? false
    }

    func testPickerReportsASelectorForExactlyTheClickedElement() throws {
        loadAndWaitForCommit(server.url("/page"))
        waitUntil("page loaded") { (try? display(of: "ad")) == "block" }
        tab.executeJavaScript(ElementHiderScript.start)
        waitUntil("picker on") { ((try? callJS("return !!window.__brwElementHider")) as? Bool) == true }

        let byId = try pick("document.getElementById('keep')")
        XCTAssertEqual(byId["type"] as? String, ElementHiderScript.pickedMessageType)
        XCTAssertEqual(byId["selector"] as? String, "#keep")

        let second = "document.querySelectorAll('li')[1]"
        let listItem = try pick(second)
        let listSelector = try XCTUnwrap(listItem["selector"] as? String)
        XCTAssertFalse(listSelector.contains("css-"), "hashed class names must not be used: \(listSelector)")
        XCTAssertTrue(try matchCount(listSelector, is: second), listSelector)

        let anonymous = "document.querySelector('section > div')"
        let anonymousSelector = try XCTUnwrap(try pick(anonymous)["selector"] as? String)
        XCTAssertTrue(try matchCount(anonymousSelector, is: anonymous), anonymousSelector)
    }

    func testPickerSwallowsThePressAndStopsCleanly() throws {
        loadAndWaitForCommit(server.url("/page"))
        waitUntil("page loaded") { (try? display(of: "ad")) == "block" }
        _ = try callJS("window.clicks = 0; document.getElementById('keep').addEventListener('pointerdown', () => window.clicks++);")
        tab.executeJavaScript(ElementHiderScript.start)
        waitUntil("picker on") { ((try? callJS("return !!window.__brwElementHider")) as? Bool) == true }

        _ = try pick("document.getElementById('keep')")
        XCTAssertEqual(try callJS("return window.clicks") as? Int, 0)

        tab.executeJavaScript(ElementHiderScript.stop)
        settle(0.2)
        let before = recorder.pageMessages.count
        _ = try callJS("""
            const el = document.getElementById('keep');
            el.dispatchEvent(new PointerEvent('pointerdown', { button: 0, bubbles: true }));
            """)
        settle(0.3)
        XCTAssertEqual(try callJS("return window.clicks") as? Int, 1, "the page gets its presses back")
        XCTAssertEqual(recorder.pageMessages.count, before, "a silent stop reports nothing")
    }
}
