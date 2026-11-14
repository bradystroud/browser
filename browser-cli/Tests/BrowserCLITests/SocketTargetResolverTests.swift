import XCTest
import BrowserCLIProtocol
@testable import BrowserCLI

final class SocketTargetResolverTests: XCTestCase {
    func testPrecedenceAndNoLookupForExplicitPaths() throws {
        let args = try SocketTargetResolver.parse(["profiles", "--socket", "/flag.sock"])
        XCTAssertEqual(try SocketTargetResolver.resolve(args: args, environment: ["BROWSER_CLI_SOCKET": "/env.sock"], systemTempDirectory: { XCTFail("lookup"); return nil }), "/flag.sock")
        XCTAssertEqual(try SocketTargetResolver.resolve(args: ArgParser.parse([]), environment: ["BROWSER_CLI_SOCKET": "/env.sock"], systemTempDirectory: { XCTFail("lookup"); return nil }), "/env.sock")
    }

    func testClientFallbackAndProfilesIsolation() throws {
        let args = ArgParser.parse(["--profiles-root", "/scratch/a"])
        let directory = DiskLocations.sessionAndProfilesMetadataDirectory(arguments: args.profilesRootArguments)
        XCTAssertEqual(try SocketTargetResolver.resolve(args: args, environment: ["TMPDIR": "/custom"], systemTempDirectory: { nil }), CLISocketPath.path(inDirectory: directory, userTempDirectory: "/custom"))
        XCTAssertEqual(try SocketTargetResolver.resolve(args: args, environment: ["TMPDIR": ""], systemTempDirectory: { nil }), CLISocketPath.path(inDirectory: directory, userTempDirectory: "/tmp/"))
        XCTAssertEqual(try SocketTargetResolver.resolve(args: args, environment: [:], systemTempDirectory: { nil }), CLISocketPath.path(inDirectory: directory, userTempDirectory: "/tmp/"))
        XCTAssertEqual(try SocketTargetResolver.resolve(args: args, environment: ["TMPDIR": "/ignored"], systemTempDirectory: { "/system" }), CLISocketPath.path(inDirectory: directory, userTempDirectory: "/system"))
        XCTAssertNotEqual(try SocketTargetResolver.resolve(args: args, environment: [:], systemTempDirectory: { "/system" }), try SocketTargetResolver.resolve(args: ArgParser.parse(["--profiles-root", "/scratch/b"]), environment: [:], systemTempDirectory: { "/system" }))
    }

    func testValidationCountsUTF8AndRejectsInvalidEnvironment() throws {
        for path in ["", "relative", "/a\0b", "/" + String(repeating: "a", count: 103), "/" + String(repeating: "é", count: 52)] {
            XCTAssertThrowsError(try SocketTargetResolver.validate(path))
            XCTAssertThrowsError(try SocketTargetResolver.resolve(args: ArgParser.parse([]), environment: ["BROWSER_CLI_SOCKET": path]))
        }
        XCTAssertNoThrow(try SocketTargetResolver.validate("/" + String(repeating: "é", count: 51)))
    }

    func testParserNestedCommandsAndOpaqueFlagValues() throws {
        for argv in [["--socket", "/test.sock", "page", "list"], ["page", "--socket", "/test.sock", "record", "stop", "p1"], ["window", "--socket", "/test.sock", "new"]] {
            XCTAssertEqual(try SocketTargetResolver.parse(argv).flags["socket"], "/test.sock")
        }
        let args = try SocketTargetResolver.parse(["page", "click", "p1", "--text", "--socket", "--selector", "--socket=/literal"])
        XCTAssertNil(args.flags["socket"])
        XCTAssertEqual(args.flags["text"], "--socket")
        XCTAssertEqual(args.flags["selector"], "--socket=/literal")
        for argv in [["profiles", "--socket"], ["profiles", "--socket", "--json"], ["profiles", "--socket=/a"], ["profiles", "--socket /a"], ["profiles", "--socket", "relative"], ["profiles", "--socket", "/valid", "--socket", ""]] {
            XCTAssertThrowsError(try SocketTargetResolver.parse(argv))
        }
    }

    func testTargetConflictsDuplicatesAndDiagnosticSources() throws {
        let root = ArgParser.parse(["--profiles-root", "/scratch"])
        XCTAssertThrowsError(try SocketTargetResolver.resolve(args: root, environment: ["BROWSER_CLI_SOCKET": "/inherited.sock"]))
        for flag in ["--socket", "--profiles-root"] {
            XCTAssertThrowsError(try SocketTargetResolver.parse(["profiles", flag, "/a", flag, "/b"]))
            XCTAssertThrowsError(try SocketTargetResolver.parse(["profiles", flag, "/a", flag, "/a"]))
        }
        let oversized = "/" + String(repeating: "x", count: 104)
        XCTAssertThrowsError(try SocketTargetResolver.resolve(args: ArgParser.parse([]), environment: ["TMPDIR": oversized], systemTempDirectory: { nil })) { error in
            XCTAssertTrue("\(error)".contains("TMPDIR"))
            XCTAssertTrue("\(error)".contains(oversized))
            XCTAssertTrue("\(error)".contains("UTF-8 bytes"))
        }
    }

    func testEmptyInheritedSocketHasSpecificDiagnosticBeforeRootConflict() {
        for args in [ArgParser.parse([]), ArgParser.parse(["--profiles-root", "/scratch"])] {
            XCTAssertThrowsError(try SocketTargetResolver.resolve(args: args, environment: ["BROWSER_CLI_SOCKET": ""])) { error in
                XCTAssertTrue("\(error)".contains("set but empty; unset it"))
                XCTAssertFalse("\(error)".contains("conflicts"))
            }
        }
    }

    func testEveryPageBooleanPreservesFollowingTargetFlag() throws {
        let booleans = ["private", "cursor", "headless", "no-wait", "wait-idle", "focus", "gone", "idle", "double", "clear", "submit", "full-page", "raw", "allow-password", "allow-popups"]
        for flag in booleans {
            XCTAssertTrue(ArgParser.valuelessFlags.contains(flag), flag)
            let parsed = try SocketTargetResolver.parse(["page", "list", "--" + flag, "--socket", "/chosen.sock"])
            XCTAssertEqual(parsed.flags["socket"], "/chosen.sock", flag)
        }
    }

    func testEntryDiscoveryAndDiskCommandRejection() {
        XCTAssertTrue(BrowserCLIEntry.run(["--socket", "/missing.sock", "socket-path", "--json"]))
        XCTAssertFalse(BrowserCLIEntry.run(["history", "search", "q", "--socket", "/missing.sock", "--json"]))
        XCTAssertFalse(BrowserCLIEntry.run(["page", "list", "--socket=bad", "--json"]))
        XCTAssertTrue(BrowserCLIEntry.run(["--help"]))
        XCTAssertTrue(BrowserCLIEntry.run(["-h"]))
        XCTAssertTrue(BrowserCLIEntry.run(["--socket", "/missing.sock", "--help"]))
        XCTAssertFalse(BrowserCLIEntry.run(["profiles", "--profiles-root", "--json"]))
    }

    func testExplicitConnectionFailureReportsOnlySelectedPath() throws {
        let path = "/tmp/browser-cli-missing-\(UUID().uuidString).sock"
        let selected = try SocketTargetResolver.resolve(args: ArgParser.parse(["--socket", path]), environment: ["BROWSER_CLI_SOCKET": "/different.sock"])
        XCTAssertThrowsError(try SocketClient.send(CLIRequest(command: "profiles"), socketPath: selected)) { error in
            guard case SocketClientError.noRunningInstance(let reported) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(reported, path)
        }
        XCTAssertThrowsError(try SocketClient.send(CLIRequest(command: "profiles"), socketPath: "/tmp/a\0b"))
    }
}
