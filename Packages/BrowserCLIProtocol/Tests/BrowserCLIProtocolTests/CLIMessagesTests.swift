import XCTest
@testable import BrowserCLIProtocol

final class CLIMessagesTests: XCTestCase {
    func testRequestRoundTrips() throws {
        let request = CLIRequest(command: "open", args: ["url": "https://example.com", "profile": "work"])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CLIRequest.self, from: data)
        XCTAssertEqual(decoded.command, "open")
        XCTAssertEqual(decoded.args["url"], "https://example.com")
        XCTAssertEqual(decoded.args["profile"], "work")
    }

    func testRequestDefaultsToEmptyArgs() throws {
        let request = CLIRequest(command: "profiles")
        XCTAssertTrue(request.args.isEmpty)
    }

    func testResponseRoundTripsWithProfiles() throws {
        let response = CLIResponse(
            ok: true,
            message: "2 profiles",
            profiles: [
                CLIProfileInfo(id: "abc", name: "default", colorHex: "#007AFF", windowCount: 1),
                CLIProfileInfo(id: "def", name: "work", colorHex: "#FF3B30", windowCount: 0),
            ]
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CLIResponse.self, from: data)
        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.error)
        XCTAssertEqual(decoded.profiles?.count, 2)
        XCTAssertEqual(decoded.profiles?[1].name, "work")
        XCTAssertNil(decoded.tabs)
    }

    func testResponseRoundTripsWithTabs() throws {
        let response = CLIResponse(
            ok: true,
            tabs: [CLITabInfo(profileName: "default", windowIndex: 0, tabIndex: 1, isActive: true, title: "Example", url: "https://example.com")]
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CLIResponse.self, from: data)
        XCTAssertEqual(decoded.tabs?.first?.title, "Example")
        XCTAssertEqual(decoded.tabs?.first?.isActive, true)
    }

    func testFailureFactory() {
        let response = CLIResponse.failure("no running instance found")
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "no running instance found")
    }

    func testSocketPathIsNestedUnderGivenDirectory() {
        XCTAssertEqual(CLISocketPath.path(inDirectory: "/tmp/scratch"), "/tmp/scratch/cli.sock")
    }
}
