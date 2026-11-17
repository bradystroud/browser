import XCTest
@testable import UpdateCore

final class ReleaseCheckTests: XCTestCase {
    private let digest = String(repeating: "ab", count: 32)

    private func releaseJSON(tag: String = "v0.1.5", assetName: String? = nil, url: String? = nil,
                             digest: String? = nil, html: String = "https://github.com/bradystroud/browser/releases/tag/v0.1.5") -> Data {
        let version = tag.dropFirst()
        let name = assetName ?? "Browser-\(version).dmg"
        var asset: [String: Any] = [
            "name": name,
            "browser_download_url": url ?? "https://github.com/bradystroud/browser/releases/download/\(tag)/\(name)",
        ]
        asset["digest"] = digest ?? "sha256:\(self.digest)"
        let payload: [String: Any] = [
            "tag_name": tag, "html_url": html, "name": "Browser \(version)",
            "assets": [["name": "Browser.dmg", "browser_download_url": "https://github.com/bradystroud/browser/releases/download/\(tag)/Browser.dmg", "digest": "sha256:\(self.digest)"], asset],
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func testNewerReleaseIsAvailableWithItsVersionedDownload() throws {
        let availability = try ReleaseCheck.availability(currentVersion: "0.1.4", latestReleaseJSON: releaseJSON())
        let release = try XCTUnwrap(availability.release)
        XCTAssertEqual(release.version, AppVersion("0.1.5"))
        XCTAssertEqual(release.asset?.url.lastPathComponent, "Browser-0.1.5.dmg")
        XCTAssertEqual(release.asset?.sha256, digest)
        XCTAssertEqual(release.name, "Browser 0.1.5")
    }

    func testSameOrOlderReleaseIsUpToDate() throws {
        XCTAssertNil(try ReleaseCheck.availability(currentVersion: "0.1.5", latestReleaseJSON: releaseJSON()).release)
        XCTAssertNil(try ReleaseCheck.availability(currentVersion: "0.2.0", latestReleaseJSON: releaseJSON()).release)
    }

    /// A release whose file is somewhere other than its own release download
    /// path is still offered, but only as a page to open.
    func testDownloadFromAnotherPlaceIsNotInstallable() throws {
        let json = releaseJSON(url: "https://example.com/Browser-0.1.5.dmg")
        let release = try XCTUnwrap(ReleaseCheck.availability(currentVersion: "0.1.4", latestReleaseJSON: json).release)
        XCTAssertNil(release.asset)
    }

    func testMissingOrMalformedDigestIsNotInstallable() throws {
        for value in ["", "sha1:abc", "sha256:XYZ", "sha256:" + String(repeating: "A", count: 64)] {
            let release = try XCTUnwrap(ReleaseCheck.availability(currentVersion: "0.1.4", latestReleaseJSON: releaseJSON(digest: value)).release)
            XCTAssertNil(release.asset, value)
        }
    }

    func testReleasePageMustBeOnGitHub() {
        XCTAssertThrowsError(try ReleaseCheck.parseRelease(releaseJSON(html: "http://github.com/x")))
        XCTAssertThrowsError(try ReleaseCheck.parseRelease(releaseJSON(html: "https://evil.example/x")))
    }

    func testNotFoundMeansNoRelease() {
        let data = Data(#"{"message":"Not Found"}"#.utf8)
        XCTAssertThrowsError(try ReleaseCheck.parseRelease(data)) { error in
            XCTAssertEqual(error as? UpdateCheckError, .noPublishedRelease)
        }
    }

    func testOtherAPIErrorsKeepTheirMessage() {
        let data = Data(#"{"message":"API rate limit exceeded"}"#.utf8)
        XCTAssertThrowsError(try ReleaseCheck.parseRelease(data)) { error in
            XCTAssertEqual(error as? UpdateCheckError, .unreadableResponse(reason: "API rate limit exceeded"))
        }
    }

    func testUnreadableCurrentVersion() {
        XCTAssertThrowsError(try ReleaseCheck.availability(currentVersion: "dev", latestReleaseJSON: releaseJSON()))
    }
}
