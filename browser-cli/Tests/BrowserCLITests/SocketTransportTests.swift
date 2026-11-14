import XCTest
import Darwin
import BrowserCLIProtocol
@testable import BrowserCLI

/// A real Unix listener, isolated from every Browser profile and process.
private final class SocketFixture {
    let path = "/tmp/brw-cli-\(UUID().uuidString).sock"
    let fd: Int32

    init() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SimpleError("fixture socket failed") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes + [0])
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            throw SimpleError("fixture bind/listen failed")
        }
    }

    deinit { close(fd); unlink(path) }

    func hasConnection(timeout: Int32) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, timeout) > 0
    }

    func respond() throws -> CLIRequest {
        guard hasConnection(timeout: 5000) else { throw SimpleError("CLI did not reach fixture") }
        let connection = accept(fd, nil, nil)
        guard connection >= 0 else { throw SimpleError("fixture accept failed") }
        defer { close(connection) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw SimpleError("fixture receive timeout failed")
        }
        var data = Data()
        var byte: UInt8 = 0
        while read(connection, &byte, 1) == 1 {
            if byte == 10 { break }
            data.append(byte)
        }
        let response = Data("{\"ok\":true,\"message\":\"fixture\"}\n".utf8)
        let written = response.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        guard written == response.count else { throw SimpleError("fixture write failed") }
        return try JSONDecoder().decode(CLIRequest.self, from: data)
    }
}

final class SocketTransportTests: XCTestCase {
    private var children: [Process] = []

    override func tearDown() {
        for child in children {
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
        }
        children.removeAll()
        super.tearDown()
    }

    private func start(_ args: [String], environment: [String: String] = [:]) throws -> (Process, Pipe, Pipe) {
        let executable = Bundle(for: SocketTransportTests.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("browser")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SimpleError("Missing browser executable beside test bundle: \(executable.path). Build the CLI in the same configuration before running transport tests.")
        }
        let process = Process()
        process.executableURL = executable
        // A wiring regression must never discover the user's running Browser.
        // Environment-only selection deliberately omits the root to avoid the
        // conflict guard; its listener is always a fresh fixture.
        let scratch = ["--profiles-root", "/tmp/brw-fixture-root-" + UUID().uuidString]
        process.arguments = args + (args.contains("--profiles-root") || environment["BROWSER_CLI_SOCKET"] != nil ? [] : scratch)
        var clean = ProcessInfo.processInfo.environment
        clean.removeValue(forKey: "BROWSER_CLI_SOCKET")
        process.environment = clean.merging(environment) { _, value in value }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        children.append(process)
        return (process, output, errors)
    }

    private func waitForExit(_ process: Process) throws {
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw SimpleError("CLI fixture subprocess timed out")
        }
        process.waitUntilExit()
    }

    private func finish(_ child: (Process, Pipe, Pipe), success: Bool = true) throws -> [String: Any] {
        try waitForExit(child.0)
        let data = child.1.fileHandleForReading.readDataToEndOfFile()
        let errors = child.2.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(child.0.terminationStatus == 0, success, String(decoding: errors + data, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testAllLiveRoutesReachExplicitSocket() throws {
        let fixture = try SocketFixture()
        let cases: [([String], String)] = [
            (["profiles", "--socket", fixture.path], "profiles"),
            (["--socket", fixture.path, "tabs"], "tabs"),
            (["windows", "--socket", fixture.path], "windows"),
            (["window", "--socket", fixture.path, "new"], "window-new"),
            (["focus", "Fixture", "--socket", fixture.path], "focus"),
            (["page", "--socket", fixture.path, "list"], "page-list"),
            (["open", "https://example.invalid", "--socket", fixture.path], "open"),
            (["page", "record", "--socket", fixture.path, "stop", "p1"], "page-record-stop"),
            (["page", "click", "p1", "--text", "--socket", "--socket", fixture.path], "page-click"),
            (["page", "click", "p1", "--text", "--help", "--socket", fixture.path], "page-click"),
        ]
        for (args, command) in cases {
            let child = try start(args + ["--json"])
            let request = try fixture.respond()
            XCTAssertEqual(request.command, command)
            XCTAssertNil(request.args["socket"])
            if command == "page-click" { XCTAssertEqual(request.args["text-target"], args[4]) }
            XCTAssertEqual(try finish(child)["ok"] as? Bool, true)
        }
    }

    func testEnvironmentSelectionAndExplicitConfirmation() throws {
        let inherited = try SocketFixture()
        let explicit = try SocketFixture()
        var child = try start(["profiles", "--json"], environment: ["BROWSER_CLI_SOCKET": inherited.path])
        XCTAssertEqual(try inherited.respond().command, "profiles")
        _ = try finish(child)
        child = try start(["profiles", "--profiles-root", "/scratch", "--json"], environment: ["BROWSER_CLI_SOCKET": inherited.path])
        XCTAssertTrue((try finish(child, success: false)["error"] as? String ?? "").contains("conflicts"))
        XCTAssertFalse(inherited.hasConnection(timeout: 0))
        child = try start(["profiles", "--profiles-root", "/scratch", "--socket", explicit.path, "--json"], environment: ["BROWSER_CLI_SOCKET": inherited.path])
        XCTAssertEqual(try explicit.respond().command, "profiles")
        _ = try finish(child)
        XCTAssertFalse(inherited.hasConnection(timeout: 0))
    }

    func testExplicitFailureNeverConnectsToInheritedOrDefaultSocket() throws {
        let inherited = try SocketFixture()
        let root = "/tmp/brw-root-\(UUID().uuidString)"
        let defaultPath = try SocketTargetResolver.resolve(args: ArgParser.parse(["--profiles-root", root]), environment: [:])
        // A default-discovery listener proves a failed explicit request does not retry there.
        let defaultFD = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(defaultFD, 0)
        defer { close(defaultFD); unlink(defaultPath) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(defaultPath.utf8) + [0]) }
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(defaultFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }, 0)
        XCTAssertEqual(listen(defaultFD, 1), 0)
        let missing = "/tmp/brw-missing-\(UUID().uuidString).sock"
        let child = try start(["profiles", "--profiles-root", root, "--socket", missing, "--json"], environment: ["BROWSER_CLI_SOCKET": inherited.path])
        let error = try finish(child, success: false)["error"] as? String ?? ""
        XCTAssertTrue(error.contains(missing))
        XCTAssertTrue(error.contains("Selected by --socket"))
        XCTAssertFalse(inherited.hasConnection(timeout: 0))
        var descriptor = pollfd(fd: defaultFD, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 0), 0)
    }

    func testHelpFlagsNeverConnect() throws {
        let fixture = try SocketFixture()
        for args in [["open", "--help"], ["profiles", "--help"], ["page", "list", "--help"], ["window", "--help", "new"]] {
            let child = try start(args + ["--socket", fixture.path])
            try waitForExit(child.0)
            XCTAssertEqual(child.0.terminationStatus, 0)
            let help = String(decoding: child.1.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if args.first == "page" { XCTAssertEqual(help, PageCommand.usage + "\n") }
            else { XCTAssertTrue(help.contains("Usage:")) }
            XCTAssertFalse(fixture.hasConnection(timeout: 0))
        }
    }
}
