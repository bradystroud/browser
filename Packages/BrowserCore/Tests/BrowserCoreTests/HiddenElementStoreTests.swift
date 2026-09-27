import XCTest
@testable import BrowserCore

final class HiddenElementStoreTests: XCTestCase {
    private var dir: URL!
    private var fileURL: URL { dir.appendingPathComponent("hidden-elements.json") }

    override func setUpWithError() throws {
        dir = try TestSupport.makeTempProfileDirectory()
    }

    override func tearDown() {
        TestSupport.removeQuietly(dir)
    }

    func testHideRoundTripsThroughTheFile() {
        let store = HiddenElementStore(fileURL: fileURL)
        XCTAssertTrue(store.hide(selector: "#cookie-banner", label: "Cookie banner", note: "1200×80 · bottom centre", onSite: "example.com"))

        let reloaded = HiddenElementStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.elements(onSite: "example.com").map(\.selector), ["#cookie-banner"])
        XCTAssertEqual(reloaded.elements(onSite: "example.com").first?.label, "Cookie banner")
        XCTAssertEqual(reloaded.sites, ["example.com"])
    }

    func testInMemoryStoreNeverWritesAFile() {
        let store = HiddenElementStore(fileURL: nil)
        XCTAssertTrue(store.hide(selector: "aside", label: "Sidebar", note: "", onSite: "example.com"))
        XCTAssertEqual(store.elements(onSite: "example.com").count, 1)
        let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(contents ?? [], [])
    }

    func testDuplicateSelectorIsNotStoredTwice() {
        let store = HiddenElementStore(fileURL: nil)
        XCTAssertTrue(store.hide(selector: "aside", label: "Sidebar", note: "", onSite: "example.com"))
        XCTAssertFalse(store.hide(selector: "aside", label: "Sidebar", note: "", onSite: "example.com"))
        XCTAssertEqual(store.elements(onSite: "example.com").count, 1)
    }

    func testSitesAreIndependent() {
        let store = HiddenElementStore(fileURL: nil)
        store.hide(selector: "aside", label: "", note: "", onSite: "one.com")
        store.hide(selector: "footer", label: "", note: "", onSite: "two.com")
        XCTAssertEqual(store.elements(onSite: "one.com").map(\.selector), ["aside"])
        XCTAssertEqual(store.elements(onSite: "two.com").map(\.selector), ["footer"])
    }

    func testSiteKeyIsTheRegistrableDomain() {
        XCTAssertEqual(HiddenElementStore.site(forHost: "www.example.com"), "example.com")
        XCTAssertEqual(HiddenElementStore.site(forHost: "news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(HiddenElementStore.site(forHost: "Example.COM"), "example.com")
    }

    func testSharedHostingOwnersAreSeparateSites() {
        XCTAssertEqual(HiddenElementStore.site(forHost: "alice.github.io"), "alice.github.io")
        XCTAssertEqual(HiddenElementStore.site(forHost: "docs.alice.github.io"), "docs.alice.github.io")
        XCTAssertEqual(HiddenElementStore.site(forHost: "my-app.vercel.app"), "my-app.vercel.app")
        XCTAssertEqual(HiddenElementStore.site(forHost: "bucket.s3.amazonaws.com."), "bucket.s3.amazonaws.com")
        XCTAssertEqual(HiddenElementStore.site(forHost: "www.someblog.blogspot.com"), "someblog.blogspot.com")
        XCTAssertNotEqual(HiddenElementStore.site(forHost: "alice.github.io"), HiddenElementStore.site(forHost: "bob.github.io"))
        // The platform's own site is still one ordinary site.
        XCTAssertEqual(HiddenElementStore.site(forHost: "github.io"), "github.io")
        XCTAssertEqual(HiddenElementStore.site(forHost: "www.github.com"), "github.com")
    }

    func testRestoreRemovesOneAndDropsAnEmptySite() {
        let store = HiddenElementStore(fileURL: fileURL)
        store.hide(selector: "aside", label: "", note: "", onSite: "example.com")
        store.hide(selector: "footer", label: "", note: "", onSite: "example.com")

        store.restore(selector: "aside", onSite: "example.com")
        XCTAssertEqual(store.elements(onSite: "example.com").map(\.selector), ["footer"])

        store.restore(selector: "footer", onSite: "example.com")
        XCTAssertEqual(store.sites, [])
        XCTAssertEqual(HiddenElementStore(fileURL: fileURL).sites, [])
    }

    func testRestoreAllClearsOnlyThatSite() {
        let store = HiddenElementStore(fileURL: nil)
        store.hide(selector: "aside", label: "", note: "", onSite: "one.com")
        store.hide(selector: "nav", label: "", note: "", onSite: "one.com")
        store.hide(selector: "footer", label: "", note: "", onSite: "two.com")

        store.restoreAll(onSite: "one.com")
        XCTAssertEqual(store.sites, ["two.com"])
    }

    func testEmptyLabelFallsBackToSelectorAndLongLabelsAreClipped() {
        let store = HiddenElementStore(fileURL: nil)
        store.hide(selector: "aside", label: "", note: "", onSite: "example.com")
        store.hide(selector: "nav", label: String(repeating: "word ", count: 100), note: "", onSite: "example.com")
        let elements = store.elements(onSite: "example.com")
        XCTAssertEqual(elements[0].label, "aside")
        XCTAssertEqual(elements[1].label.count, HiddenElementStore.maximumLabelLength)
        XCTAssertTrue(elements[1].label.hasSuffix("…"))
    }

    func testStyleSheetsCarryOneRulePerSelector() {
        let store = HiddenElementStore(fileURL: nil)
        store.hide(selector: "#a", label: "", note: "", onSite: "example.com")
        store.hide(selector: "div.b > p", label: "", note: "", onSite: "example.com")
        XCTAssertEqual(store.styleSheetsBySite, [
            "example.com": "#a { display: none !important; }\ndiv.b > p { display: none !important; }",
        ])
    }

    // MARK: - Selector safety

    func testOrdinarySelectorsAreAccepted() {
        for selector in [
            "#main",
            "div.card.promo",
            "section:nth-of-type(2) > div",
            "button[aria-label=\"Close; now\"]",
            "a[data-testid='x']",
            "#\\31 23",
            "div[title=\"it's\"]",
            "li:not(.a, :is(.b, .c)) > span",
            "a[title=\"(]\"]",
            "#\\28 x",
        ] {
            XCTAssertTrue(HiddenElementStyleSheet.isAcceptableSelector(selector), selector)
        }
    }

    func testSelectorsThatCouldEscapeTheirRuleAreRejected() {
        for selector in [
            "",
            "   ",
            "a } body { display: none",
            "a { color: red",
            "div; body",
            "@import url(x)",
            "a /* comment",
            "div[title=\"unterminated]",
            "a\\",
            "a\nb",
            "div[title=\"}\"]",
            "a:is(",
            "a:is(b",
            "a)",
            "div[title",
            "div]",
            "a:not(b))(",
            "div[title=\"x\"",
            String(repeating: "a", count: HiddenElementStyleSheet.maximumSelectorLength + 1),
        ] {
            XCTAssertFalse(HiddenElementStyleSheet.isAcceptableSelector(selector), selector)
        }
    }

    func testUnsafeSelectorIsNotStored() {
        let store = HiddenElementStore(fileURL: nil)
        XCTAssertFalse(store.hide(selector: "a } body { display: none", label: "", note: "", onSite: "example.com"))
        XCTAssertEqual(store.sites, [])
    }

    func testUnsafeSelectorInAStoredFileNeverReachesTheSheet() throws {
        let tampered = ["example.com": [
            HiddenElement(selector: "a } body { display: none", label: "", note: "", dateHidden: Date()),
            HiddenElement(selector: "aside", label: "", note: "", dateHidden: Date()),
        ]]
        try JSONEncoder().encode(tampered).write(to: fileURL)
        let store = HiddenElementStore(fileURL: fileURL)
        XCTAssertEqual(store.styleSheetsBySite["example.com"], "aside { display: none !important; }")
    }
}
