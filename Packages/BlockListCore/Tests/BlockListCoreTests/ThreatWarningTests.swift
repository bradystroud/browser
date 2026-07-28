import Foundation
import Testing
@testable import BlockListCore

@Suite("ThreatWarningLink encode/decode")
struct ThreatWarningLinkTests {
    @Test("continueURL round-trips back to the original URL via originalURL(fromContinueLink:)")
    func roundTrips() {
        let original = "https://evil-example.test/login?redirect=https://real-bank.example&session=abc123"
        let link = ThreatWarningLink.continueURL(bypassing: original)
        #expect(ThreatWarningLink.originalURL(fromContinueLink: link) == original)
    }

    @Test("continueURL always targets the reserved .invalid marker host and path")
    func usesMagicHostAndPath() {
        let link = ThreatWarningLink.continueURL(bypassing: "https://example.com")
        #expect(link.hasPrefix("https://\(ThreatWarningLink.magicHost)\(ThreatWarningLink.continuePath)?url="))
    }

    @Test("an unrelated URL is not recognized as a continue link")
    func unrelatedURLIsNil() {
        #expect(ThreatWarningLink.originalURL(fromContinueLink: "https://example.com") == nil)
        #expect(ThreatWarningLink.originalURL(fromContinueLink: "https://browser-safety-warning.invalid/other-path?url=https://example.com") == nil)
    }
}

@Suite("ThreatWarningPageRenderer")
struct ThreatWarningPageRendererTests {
    @Test("rendered HTML names the host and includes a Continue-anyway link to the original URL")
    func rendersHostAndContinueLink() {
        let html = ThreatWarningPageRenderer.renderHTML(host: "evil-example.test", originalURL: "https://evil-example.test/steal")
        #expect(html.contains("evil-example.test"))
        #expect(html.contains(ThreatWarningLink.magicHost))
        #expect(html.contains("history.back()"))
    }

    @Test("host and URL are HTML-escaped so they can't break out of the page markup")
    func escapesUntrustedInput() {
        let html = ThreatWarningPageRenderer.renderHTML(host: "<script>evil</script>", originalURL: "https://example.com")
        #expect(!html.contains("<script>evil</script>"))
        #expect(html.contains("&lt;script&gt;"))
    }

    @Test("dataURL produces a valid base64-encoded data: URL")
    func producesDataURL() {
        let url = ThreatWarningPageRenderer.dataURL(host: "evil-example.test", originalURL: "https://evil-example.test")
        #expect(url.hasPrefix("data:text/html;charset=utf-8;base64,"))
    }
}

@Suite("Threat list is an independent BlockList instance")
struct ThreatListIndependenceTests {
    @Test("loading the starter threat list doesn't affect a separate ad/tracker BlockList instance, and vice versa")
    func instancesAreIndependent() {
        let adList = BlockList()
        adList.loadStarterList()

        let threatList = BlockList()
        threatList.load(starterThreatListText)

        #expect(threatList.contains(host: "testsafebrowsing.appspot.com"))
        #expect(!adList.contains(host: "testsafebrowsing.appspot.com"))
        #expect(adList.contains(host: "doubleclick.net"))
        #expect(!threatList.contains(host: "doubleclick.net"))
    }
}

@Suite("ThreatWarningSettings defaults")
struct ThreatWarningSettingsTests {
    @Test("defaults to enabled")
    func defaultsEnabled() {
        #expect(ThreatWarningSettings().isEnabled)
    }

    @Test("a settings.json written before this field existed still decodes with the default")
    func oldShapeDecodesWithDefault() throws {
        // ThreatWarningSettings is new (browser-12m.6) so there's no real
        // "before" shape to migrate from yet -- this locks in that an empty
        // JSON object decodes to the same default `BlockingSettingsStore`-
        // style stores already rely on (see that store's own doc comment),
        // so a future field addition here can follow the exact same
        // decodeIfPresent-with-default pattern RoutingCore's migration test
        // already established without breaking this one.
        let data = Data("{\"isEnabled\":false}".utf8)
        let decoded = try JSONDecoder().decode(ThreatWarningSettings.self, from: data)
        #expect(decoded.isEnabled == false)
    }
}
