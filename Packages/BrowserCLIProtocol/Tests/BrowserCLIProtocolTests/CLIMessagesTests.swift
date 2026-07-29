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

    func testSocketPathIsDeterministic() {
        XCTAssertEqual(CLISocketPath.path(inDirectory: "/tmp/scratch"), CLISocketPath.path(inDirectory: "/tmp/scratch"))
    }

    func testSocketPathDiffersForDifferentDirectories() {
        XCTAssertNotEqual(CLISocketPath.path(inDirectory: "/tmp/scratch-a"), CLISocketPath.path(inDirectory: "/tmp/scratch-b"))
    }

    /// The whole reason this isn't just `<directory>/cli.sock` (see
    /// CLISocketPath's own doc comment): sockaddr_un.sun_path is 104 bytes
    /// on macOS, and a real --profiles-root can plausibly be longer than
    /// that on its own (an agent's own scratch-directory path did exactly
    /// this during manual testing). The generated path itself must always
    /// stay comfortably short, regardless of how long the input directory
    /// is.
    func testSocketPathStaysShortEvenForALongDirectory() {
        let longDirectory = "/private/tmp/claude-501/-some-very-long-session-identifier-dir/ff2935c2-2cf0-4314-8d3d-2ede03b435b9/scratchpad/cli-e2e-profiles"
        XCTAssertGreaterThan(longDirectory.utf8.count, 104)
        XCTAssertLessThan(CLISocketPath.path(inDirectory: longDirectory).utf8.count, 104)
    }
}
