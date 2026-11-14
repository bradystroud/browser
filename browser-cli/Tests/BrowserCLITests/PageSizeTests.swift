import XCTest
import Darwin
import BrowserCLIProtocol
@testable import BrowserCLI

final class PageSizeTests: XCTestCase {
    func testViewportFlagAndResizeIdParseTogether() throws {
        let args = ArgParser.parse(["resize", "p1", "--viewport", "1920x1080", "--json"])
        XCTAssertEqual(args.positionals, ["resize", "p1"])
        XCTAssertTrue(args.jsonOutput)
        XCTAssertEqual(try CLIPageSize.parse(args.flags, requiresViewport: true)?.height, 1080)
    }

    func testInvalidSizeFailsBeforeSocketConnection() throws {
        for (argv, expected) in [
            (["resize", "p1", "--viewport", "nanx600", "--json"], "Page dimensions must be integers"),
            (["open", "--width", "800", "--json"], "--width and --height must be supplied together"),
            (["resize", "p1", "--json"], "page resize requires --viewport")
        ] {
            let pipe = Pipe()
            fflush(stdout)
            let original = dup(STDOUT_FILENO)
            XCTAssertGreaterThanOrEqual(original, 0)
            dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
            let succeeded = PageCommand.run(argv: argv)
            fflush(stdout)
            dup2(original, STDOUT_FILENO)
            close(original)
            try pipe.fileHandleForWriting.close()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let response = try JSONDecoder().decode(CLIResponse.self, from: data)
            XCTAssertFalse(succeeded)
            XCTAssertTrue(response.error?.hasPrefix(expected) == true, "Unexpected error: \(response.error ?? "missing")")
        }
    }

    func testOlderServerCannotSilentlyIgnoreViewport() {
        let old = CLIResponse(ok: true, page: CLIPageInfo(id: "p1", profileName: "test", isPrivate: false,
                                                         url: "about:blank", title: "", isLoading: false))
        XCTAssertNotNil(PageCommand.viewportCompatibilityError(old, requested: true))
        XCTAssertNil(PageCommand.viewportCompatibilityError(old, requested: false))
        let current = CLIResponse(ok: true, page: CLIPageInfo(id: "p1", profileName: "test", isPrivate: false,
                                                             url: "about:blank", title: "", isLoading: false,
                                                             viewportWidth: 1920, viewportHeight: 1080))
        XCTAssertNil(PageCommand.viewportCompatibilityError(current, requested: true))
        let busy = CLIResponse(ok: true, page: CLIPageInfo(id: "p1", profileName: "test", isPrivate: false,
                                                          url: "about:blank", title: "", isLoading: false, zoomFactor: 1))
        XCTAssertNil(PageCommand.viewportCompatibilityError(busy, requested: true))
        XCTAssertTrue(PageCommand.render(current).contains("1920x1080"))
    }
}
