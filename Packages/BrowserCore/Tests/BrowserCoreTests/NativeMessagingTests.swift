import XCTest
@testable import BrowserCore

final class NativeMessagingTests: XCTestCase {
    private var dir: URL!
    private let origin = "chrome-extension://abcdefghijklmnopabcdefghijklmnop/"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("native-messaging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixtures

    /// A host script in Perl, which every Mac has, so the tests need no
    /// build step. `body` runs after the helpers are defined.
    private func makeHost(_ name: String, body: String) throws -> URL {
        let script = """
        #!/usr/bin/perl
        use strict; binmode STDIN; binmode STDOUT; $| = 1;
        sub readmsg { my $h; return undef if read(STDIN, $h, 4) != 4; my $n = unpack("L", $h); my $b = ''; read(STDIN, $b, $n); return $b; }
        sub writemsg { my ($b) = @_; print pack("L", length($b)) . $b; }
        \(body)
        """
        let url = dir.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func writeManifest(name: String, path: String, type: String = "stdio", origins: [String]? = nil, in folder: URL? = nil) throws {
        let folder = folder ?? dir!
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": name, "description": "test", "path": path, "type": type, "allowed_origins": origins ?? [origin]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent(name + ".json"))
    }

    private func run(_ manifest: NativeMessagingManifest, send messages: [Any], expecting count: Int) throws -> (messages: [Any], exit: NativeMessagingError?) {
        let host = NativeMessagingHostProcess(manifest: manifest, origin: origin, queue: .main)
        var received: [Any] = []
        var exitReason: NativeMessagingError?
        let done = expectation(description: "finished")
        host.onMessage = { message in
            received.append(message)
            if received.count == count { host.stop() }
        }
        host.onExit = { reason in
            exitReason = reason
            done.fulfill()
        }
        try host.start()
        for message in messages { try host.send(message) }
        wait(for: [done], timeout: 10)
        return (received, exitReason)
    }

    // MARK: - Host names and manifests

    func testHostNameRules() {
        XCTAssertTrue(NativeMessagingHostLocator.isValidHostName("com.microsoft.browsercore"))
        XCTAssertTrue(NativeMessagingHostLocator.isValidHostName("a_b.c1"))
        for bad in ["", "Com.Example", "a..b", ".a", "a.", "../evil", "a/b", "a-b"] {
            XCTAssertFalse(NativeMessagingHostLocator.isValidHostName(bad), bad)
        }
    }

    func testFindsAllowedHost() throws {
        try writeManifest(name: "com.example.host", path: "/usr/bin/true")
        let manifest = try NativeMessagingHostLocator.find(name: "com.example.host", origin: origin, directories: [dir])
        XCTAssertEqual(manifest.path, "/usr/bin/true")
    }

    func testRefusesOriginNotInAllowedOrigins() throws {
        try writeManifest(name: "com.example.host", path: "/usr/bin/true", origins: ["chrome-extension://someoneelse/"])
        XCTAssertThrowsError(try NativeMessagingHostLocator.find(name: "com.example.host", origin: origin, directories: [dir])) { error in
            XCTAssertEqual(error as? NativeMessagingError, .forbidden(host: "com.example.host", origin: origin))
        }
    }

    func testFirstFolderWithTheManifestDecides() throws {
        let first = dir.appendingPathComponent("first")
        let second = dir.appendingPathComponent("second")
        try writeManifest(name: "com.example.host", path: "/usr/bin/true", origins: ["chrome-extension://someoneelse/"], in: first)
        try writeManifest(name: "com.example.host", path: "/usr/bin/true", in: second)
        XCTAssertThrowsError(try NativeMessagingHostLocator.find(name: "com.example.host", origin: origin, directories: [first, second]))
        XCTAssertNoThrow(try NativeMessagingHostLocator.find(name: "com.example.host", origin: origin, directories: [dir.appendingPathComponent("none"), second]))
    }

    func testRejectsBadManifests() throws {
        try writeManifest(name: "com.example.relative", path: "bin/host")
        try writeManifest(name: "com.example.socket", path: "/usr/bin/true", type: "socket")
        for name in ["com.example.relative", "com.example.socket"] {
            XCTAssertThrowsError(try NativeMessagingHostLocator.find(name: name, origin: origin, directories: [dir])) { error in
                guard case .invalidManifest = error as? NativeMessagingError else { return XCTFail("\(name): \(error)") }
            }
        }
        XCTAssertThrowsError(try NativeMessagingHostLocator.find(name: "com.example.missing", origin: origin, directories: [dir])) { error in
            XCTAssertEqual(error as? NativeMessagingError, .hostNotFound("com.example.missing"))
        }
    }

    func testManifestNameMustMatchTheFile() throws {
        try writeManifest(name: "com.example.other", path: "/usr/bin/true")
        try FileManager.default.moveItem(at: dir.appendingPathComponent("com.example.other.json"), to: dir.appendingPathComponent("com.example.host.json"))
        XCTAssertThrowsError(try NativeMessagingHostLocator.find(name: "com.example.host", origin: origin, directories: [dir]))
    }

    // MARK: - Framing

    func testFrameRoundTripsInPieces() throws {
        let frame = try NativeMessagingFrame.encode(["method": "Ping", "n": 1] as [String: Any])
            + NativeMessagingFrame.encode("second")
        var reader = NativeMessagingFrame.Reader()
        var messages: [Any] = []
        for byte in frame { messages += try reader.append(Data([byte])) }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual((messages[0] as? [String: Any])?["method"] as? String, "Ping")
        XCTAssertEqual(messages[1] as? String, "second")
    }

    func testOversizedFrameFromHostIsRefused() {
        var length = UInt32(NativeMessagingFrame.maximumFromHost + 1)
        var reader = NativeMessagingFrame.Reader()
        XCTAssertThrowsError(try reader.append(Data(bytes: &length, count: 4)))
    }

    // MARK: - Running a host

    func testEchoHostOverALongLivedConnection() throws {
        let path = try makeHost("echo", body: "while (defined(my $m = readmsg())) { writemsg($m); }")
        let manifest = NativeMessagingManifest(name: "com.example.echo", path: path.path, type: "stdio", allowedOrigins: [origin])
        let result = try run(manifest, send: [["a": 1], ["b": 2]], expecting: 2)
        XCTAssertEqual(result.messages.compactMap { ($0 as? [String: Int])?.keys.first }, ["a", "b"])
        XCTAssertNil(result.exit)
    }

    func testHostGetsTheOriginAsItsArgument() throws {
        let path = try makeHost("origin", body: #"readmsg(); writemsg('"' . $ARGV[0] . '"');"#)
        let manifest = NativeMessagingManifest(name: "com.example.origin", path: path.path, type: "stdio", allowedOrigins: [origin])
        let result = try run(manifest, send: ["hello"], expecting: 1)
        XCTAssertEqual(result.messages.first as? String, origin)
    }

    func testReplyIsKeptWhenTheHostExitsAtOnce() throws {
        let path = try makeHost("once", body: #"readmsg(); writemsg('{"ok":true}'); exit 0;"#)
        let manifest = NativeMessagingManifest(name: "com.example.once", path: path.path, type: "stdio", allowedOrigins: [origin])
        let result = try run(manifest, send: ["hello"], expecting: 2)
        XCTAssertEqual((result.messages.first as? [String: Bool])?["ok"], true)
        XCTAssertEqual(result.exit, .hostExited)
    }
}
