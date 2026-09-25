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

    func testResponseRoundTripsWithWindows() throws {
        let response = CLIResponse(
            ok: true,
            message: "2 window(s)",
            windows: [
                CLIWindowInfo(
                    profileName: "work", profileId: "abc", windowIndex: 0, tabCount: 3,
                    isPrivate: false, activeTabTitle: "Example", activeTabURL: "https://example.com"
                ),
                CLIWindowInfo(
                    profileName: "Private", profileId: "private-xyz", windowIndex: 1, tabCount: 1,
                    isPrivate: true, activeTabTitle: "", activeTabURL: "about:blank"
                ),
            ]
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(CLIResponse.self, from: data)
        XCTAssertEqual(decoded.windows?.count, 2)
        XCTAssertEqual(decoded.windows?[0].tabCount, 3)
        XCTAssertEqual(decoded.windows?[1].isPrivate, true)
        XCTAssertNil(decoded.tabs)
        XCTAssertNil(decoded.profiles)
    }

    /// An older `browser` binary talking to a newer app (or vice versa)
    /// shouldn't fail to decode just because one side doesn't know about
    /// `windows` yet -- every payload field is optional precisely so the
    /// two halves can be updated independently (they're separately signed
    /// artifacts: the CLI is symlinked onto PATH, the app is replaced by
    /// scripts/install.sh).
    func testResponseWithoutWindowsFieldStillDecodes() throws {
        let json = Data(#"{"ok":true,"message":"1 profile(s)"}"#.utf8)
        let decoded = try JSONDecoder().decode(CLIResponse.self, from: json)
        XCTAssertTrue(decoded.ok)
        XCTAssertNil(decoded.windows)
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

    func testSocketPathLivesInThePerUserTempDirectory() {
        let path = CLISocketPath.path(inDirectory: "/tmp/scratch")
        let userTemp = CLISocketPath.userTempDirectory()
        XCTAssertTrue(userTemp.hasPrefix("/var/folders/") || userTemp.hasPrefix("/private/var/folders/"), userTemp)
        XCTAssertTrue(path.hasPrefix(userTemp), path)
        XCTAssertFalse(path.hasPrefix("/tmp/"), path)
    }

    /// The real per-user temp directory, and the longest shape one takes
    /// (a `/private`-prefixed `/var/folders/xx/<28 chars>/T/`), must both
    /// leave the socket path inside sun_path's 104 bytes, NUL included.
    func testSocketPathFitsSunPathUnderTheUserTempDirectory() {
        let longDirectory = String(repeating: "d", count: 300)
        let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        XCTAssertEqual(sunPathSize, 104)
        XCTAssertLessThan(CLISocketPath.path(inDirectory: longDirectory).utf8.count, sunPathSize)
        let longestUserTemp = "/private/var/folders/zz/" + String(repeating: "x", count: 28) + "0000gn/T/"
        XCTAssertLessThan(
            CLISocketPath.path(inDirectory: longDirectory, userTempDirectory: longestUserTemp).utf8.count,
            sunPathSize
        )
    }

    func testSocketPathJoinsATempDirectoryWithoutTrailingSlash() {
        XCTAssertEqual(
            CLISocketPath.path(inDirectory: "/x", userTempDirectory: "/base"),
            CLISocketPath.path(inDirectory: "/x", userTempDirectory: "/base/")
        )
    }
}
