import XCTest
@testable import UpdateCore

final class AppcastDocumentTests: XCTestCase {
    /// The real published 0.1.0 release: tag v0.1.0, asset Browser-0.1.0.dmg,
    /// 152784041 bytes (`gh release view --repo bradystroud/browser`). The
    /// signature is a stand-in -- the real one can only be produced by the
    /// private key in Brady's Keychain -- but every other field is the
    /// release as it actually exists.
    private func release010(signature: String = "SIGNATURE_0_1_0") -> AppcastItem {
        AppcastItem(
            version: AppVersion("0.1.0")!,
            title: "Browser 0.1.0",
            link: "https://github.com/bradystroud/browser/releases/tag/v0.1.0",
            pubDate: "Tue, 11 Aug 2026 21:10:50 +0000",
            enclosureURL: "https://github.com/bradystroud/browser/releases/download/v0.1.0/Browser-0.1.0.dmg",
            enclosureLength: 152_784_041,
            edSignature: signature,
            minimumSystemVersion: "12.0.0"
        )
    }

    private func release020() -> AppcastItem {
        AppcastItem(
            version: AppVersion("0.2.0")!,
            title: "Browser 0.2.0",
            link: "https://github.com/bradystroud/browser/releases/tag/v0.2.0",
            pubDate: "Thu, 20 Aug 2026 06:00:00 +1000",
            enclosureURL: "https://github.com/bradystroud/browser/releases/download/v0.2.0/Browser-0.2.0.dmg",
            enclosureLength: 153_000_000,
            edSignature: "SIGNATURE_0_2_0",
            minimumSystemVersion: "12.0.0"
        )
    }

    func testRenderedFeedRoundTrips() throws {
        let items = [release020(), release010()]
        let parsed = try AppcastDocument.parseItems(xml: AppcastDocument.render(items: items))
        XCTAssertEqual(parsed, items)
    }

    func testRenderedFeedIsWellFormedRSSWithSparkleNamespace() {
        let xml = AppcastDocument.render(items: [release010()])
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"utf-8\"?>"))
        XCTAssertTrue(xml.contains("xmlns:sparkle=\"http://www.andymatuschak.org/xml-namespaces/sparkle\""))
        XCTAssertTrue(xml.contains("<sparkle:version>0.1.0</sparkle:version>"))
        XCTAssertTrue(xml.contains("length=\"152784041\""))
        XCTAssertTrue(xml.contains("type=\"application/octet-stream\""))
        XCTAssertTrue(xml.contains("Browser-0.1.0.dmg"))
    }

    func testItemsAlwaysRenderNewestFirst() throws {
        let xml = AppcastDocument.render(items: [release010(), release020()])
        let firstVersionRange = try XCTUnwrap(xml.range(of: "<sparkle:version>"))
        XCTAssertTrue(xml[firstVersionRange.upperBound...].hasPrefix("0.2.0"))
    }

    func testUpsertAddsNewVersionNewestFirst() {
        let merged = AppcastDocument.upsert(release020(), into: [release010()])
        XCTAssertEqual(merged.map(\.version.description), ["0.2.0", "0.1.0"])
    }

    /// Re-cutting a release (failed notarization, re-uploaded DMG) must
    /// replace the entry, not append a second one claiming the same version
    /// with a different signature.
    func testUpsertReplacesSameVersionRatherThanDuplicating() {
        let corrected = release010(signature: "CORRECTED_SIGNATURE")
        let merged = AppcastDocument.upsert(corrected, into: [release020(), release010()])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.map(\.version.description), ["0.2.0", "0.1.0"])
        XCTAssertEqual(merged.last?.edSignature, "CORRECTED_SIGNATURE")
    }

    /// "0.2" and "0.2.0" are the same release written two ways; treating
    /// them as different would put two entries for one build in the feed.
    func testUpsertTreatsEquivalentVersionSpellingsAsOneRelease() {
        var shortForm = release020()
        shortForm.version = AppVersion("0.2")!
        let merged = AppcastDocument.upsert(shortForm, into: [release020(), release010()])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.version.description, "0.2")
    }

    func testParsesSparkleOwnSampleAppcastShape() throws {
        // Trimmed from Sparkle 2.9.6's own SampleAppcast.xml: attribute
        // order, the sparkle: prefix on enclosure attributes, and an item
        // carrying fields we do not render ourselves.
        let xml = """
        <?xml version="1.0" standalone="yes"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
            <channel>
                <title>Sparkle Test App Changelog</title>
                <link>https://sparkle-project.org/files/sparkletestcast.xml</link>
                <description>Most recent changes with links to updates.</description>
                <language>en</language>
                <item>
                    <title>Version 2.0</title>
                    <sparkle:releaseNotesLink>https://sparkle-project.org/files/release-notes.html</sparkle:releaseNotesLink>
                    <pubDate>Mon, 30 May 2022 12:20:11 +0000</pubDate>
                    <sparkle:version>2.0</sparkle:version>
                    <sparkle:minimumSystemVersion>10.13</sparkle:minimumSystemVersion>
                    <enclosure url="https://sparkle-project.org/files/Sparkle_Test_App.zip" length="1623481" type="application/octet-stream" sparkle:edSignature="7cLALFUHSwvEJWSkV8aMreoBe4fhRa4FncC5NoThKxwThL6FDR7hTiPJh1fo2uagnPogisnQsgFgq6mGkt2RBw=="/>
                </item>
            </channel>
        </rss>
        """
        let items = try AppcastDocument.parseItems(xml: xml)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].version.description, "2.0")
        XCTAssertEqual(items[0].enclosureLength, 1_623_481)
        XCTAssertEqual(items[0].minimumSystemVersion, "10.13")
        XCTAssertTrue(items[0].edSignature.hasPrefix("7cLALFUHSwvEJWSkV8aMreoBe4fhRa4Fnc"))
    }

    func testParsingRejectsMalformedXML() {
        XCTAssertThrowsError(try AppcastDocument.parseItems(xml: "<rss><channel><item>"))
    }

    /// An item with no enclosure signature is an unverifiable update. It must
    /// fail loudly at publish time, not be silently carried into the feed.
    func testParsingRejectsItemWithoutSignature() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><title>Browser</title>
            <item>
              <title>Browser 0.1.0</title>
              <sparkle:version>0.1.0</sparkle:version>
              <enclosure url="https://example.com/Browser-0.1.0.dmg" length="10" type="application/octet-stream"/>
            </item>
          </channel>
        </rss>
        """
        XCTAssertThrowsError(try AppcastDocument.parseItems(xml: xml))
    }

    func testRFC822DateIsLocaleIndependent() {
        // 2026-08-20T06:00:00Z
        let date = Date(timeIntervalSince1970: 1_787_205_600)
        let rendered = AppcastDocument.rfc822(date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(rendered, "Thu, 20 Aug 2026 06:00:00 +0000")
    }

    func testEscapesXMLSpecialCharactersInFields() {
        var item = release010()
        item.title = "Browser 0.1.0 <fast & \"small\">"
        let xml = AppcastDocument.render(items: [item])
        XCTAssertTrue(xml.contains("Browser 0.1.0 &lt;fast &amp; &quot;small&quot;&gt;"))
        XCTAssertNoThrow(try AppcastDocument.parseItems(xml: xml))
    }
}
