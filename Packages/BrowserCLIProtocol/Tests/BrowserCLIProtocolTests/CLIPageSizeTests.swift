import XCTest
@testable import BrowserCLIProtocol

final class CLIPageSizeTests: XCTestCase {
    func testViewportAndLegacyDimensions() throws {
        let viewport = try XCTUnwrap(CLIPageSize.parse(["viewport": "1920x1080"]))
        XCTAssertEqual(viewport.width, 1920)
        XCTAssertEqual(viewport.height, 1080)
        XCTAssertTrue(viewport.isViewport)
        XCTAssertFalse(try XCTUnwrap(CLIPageSize.parse(["width": "800", "height": "600"])).isViewport)
        XCTAssertNil(try CLIPageSize.parse([:]))
    }

    func testMalformedAndUnboundedDimensionsAreRejected() {
        for value in ["", "1920", "1920X1080", "1920x1080x1", "NaNx600", "infx600", "200.5x600", "-200x600", "0x600", "8193x600", "8192x8192", "999999999999999999999999x600", "1920x"] {
            XCTAssertThrowsError(try CLIPageSize.parse(["viewport": value]), value)
        }
        for args in [["width": "800"], ["height": "600"], ["viewport": "800x600", "width": "800"], ["width": "nan", "height": "600"]] {
            XCTAssertThrowsError(try CLIPageSize.parse(args))
        }
        XCTAssertThrowsError(try CLIPageSize.parse([:], requiresViewport: true))
        XCTAssertThrowsError(try CLIPageSize.parse(["width": "800", "height": "600"], requiresViewport: true))
    }

    func testPageGeometryRemainsCompatibleWithOlderResponses() throws {
        let page = CLIPageInfo(id: "p1", profileName: "test", isPrivate: false, url: "about:blank", title: "", isLoading: false, viewportWidth: 1920, viewportHeight: 1080)
        let decoded = try JSONDecoder().decode(CLIPageInfo.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(decoded.viewportWidth, 1920)
        XCTAssertEqual(decoded.viewportHeight, 1080)
        let old = Data(#"{"id":"p1","profileName":"test","isPrivate":false,"url":"about:blank","title":"","isLoading":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CLIPageInfo.self, from: old).viewportWidth)
    }
}
