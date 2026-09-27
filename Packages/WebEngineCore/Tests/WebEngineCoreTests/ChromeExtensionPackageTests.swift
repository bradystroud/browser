import XCTest
@testable import WebEngineCore

final class ChromeExtensionPackageTests: XCTestCase {
    /// The id of fixture-hello.crx's throwaway key, worked out independently
    /// of this code: `openssl rsa -pubout -outform DER | shasum -a 256`,
    /// first 32 hex digits mapped 0-f to a-p.
    private let fixtureID = "pgmnddkfhcbihfijmfgancppilgkimei"

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "fixture-hello", withExtension: "crx", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    // MARK: - CRX3

    func testRealChromePackedCrxVerifiesAgainstItsID() throws {
        let zip = try Crx3.verifiedArchive(fixture(), expectedID: fixtureID)
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4b, 0x03, 0x04], "the archive after the header is a zip")
        let names = try ZipArchive.entries(in: zip).map(\.name).sorted()
        XCTAssertEqual(names, ["manifest.json", "popup.html"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("crx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try ZipArchive.extract(zip, into: folder)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["name"] as? String, "Fixture Hello", "Chrome's deflated entries inflate byte-exact")
    }

    func testHeaderCarriesTheIDAndAKeyThatHashesToIt() throws {
        let header = try Crx3.parse(fixture())
        XCTAssertEqual(ChromeExtensionID.letters(header.crxID), fixtureID)
        XCTAssertTrue(header.rsaProofs.contains { ChromeExtensionID.from(publicKey: $0.publicKey) == fixtureID })
    }

    func testAnotherExtensionsIDIsRefused() throws {
        let other = String(repeating: "a", count: 32)
        XCTAssertThrowsError(try Crx3.verifiedArchive(fixture(), expectedID: other)) { error in
            XCTAssertEqual(error as? Crx3Error, .idMismatch(expected: other, found: fixtureID))
        }
    }

    func testAlteredArchiveFailsTheSignature() throws {
        var crx = try fixture()
        crx[crx.count - 30] ^= 0xff
        XCTAssertThrowsError(try Crx3.verifiedArchive(crx, expectedID: fixtureID)) { error in
            XCTAssertEqual(error as? Crx3Error, .signatureInvalid)
        }
    }

    func testAlteredSignatureFails() throws {
        let original = try fixture()
        let header = try Crx3.parse(original)
        let signature = try XCTUnwrap(header.rsaProofs.first?.signature)
        let range = try XCTUnwrap(original.range(of: signature))
        var crx = original
        crx[range.lowerBound + 10] ^= 0x01
        XCTAssertThrowsError(try Crx3.verifiedArchive(crx, expectedID: fixtureID)) { error in
            XCTAssertEqual(error as? Crx3Error, .signatureInvalid)
        }
    }

    func testNonCrxAndOldFormatsAreRefused() throws {
        XCTAssertThrowsError(try Crx3.parse(Data("PK\u{3}\u{4}not a crx".utf8))) { XCTAssertEqual($0 as? Crx3Error, .notACrx) }
        var crx2 = try fixture()
        crx2[4] = 2
        XCTAssertThrowsError(try Crx3.parse(crx2)) { XCTAssertEqual($0 as? Crx3Error, .unsupportedFormatVersion(2)) }
        XCTAssertThrowsError(try Crx3.parse(Data())) { XCTAssertEqual($0 as? Crx3Error, .notACrx) }
    }

    func testHeaderLengthPastTheEndIsMalformed() throws {
        var crx = try fixture()
        crx[8] = 0xff; crx[9] = 0xff; crx[10] = 0xff; crx[11] = 0x7f
        XCTAssertThrowsError(try Crx3.parse(crx)) { XCTAssertEqual($0 as? Crx3Error, .malformedHeader) }
    }

    func testTruncatedProtobufIsMalformedNotACrash() {
        XCTAssertNil(Crx3.protobufLengthDelimitedFields([0x12, 0x05, 0x01]))
        XCTAssertNil(Crx3.protobufLengthDelimitedFields([0xff, 0xff, 0xff]))
        XCTAssertEqual(Crx3.protobufLengthDelimitedFields([0x08, 0x01, 0x12, 0x01, 0x07])?.map(\.field), [2])
    }

    // MARK: - Ids

    func testIDHelpers() {
        XCTAssertTrue(ChromeExtensionID.isValid(fixtureID))
        XCTAssertFalse(ChromeExtensionID.isValid("pgmnddkfhcbihfijmfgancppilgkime"))
        XCTAssertFalse(ChromeExtensionID.isValid("zgmnddkfhcbihfijmfgancppilgkimei"))
        XCTAssertEqual(ChromeExtensionID.letters([0x01, 0xfa]), "abpk")
        XCTAssertEqual(ChromeExtensionID.fromUnpackedPath("/Users/me/ext").count, 32)
        XCTAssertEqual(ChromeExtensionID.fromUnpackedPath("/a"), ChromeExtensionID.fromUnpackedPath("/a"))
        XCTAssertNotEqual(ChromeExtensionID.fromUnpackedPath("/a"), ChromeExtensionID.fromUnpackedPath("/b"))
    }

    func testFindsIDInStoreLinks() {
        let id = "nngceckbapebfimnlniiiahkandclblb"
        XCTAssertEqual(ChromeExtensionID.find(in: "https://chromewebstore.google.com/detail/bitwarden/\(id)"), id)
        XCTAssertEqual(ChromeExtensionID.find(in: "https://chrome.google.com/webstore/detail/\(id)?hl=en"), id)
        XCTAssertEqual(ChromeExtensionID.find(in: id.uppercased()), id)
        XCTAssertNil(ChromeExtensionID.find(in: "https://example.com/"))
        XCTAssertNil(ChromeExtensionID.find(in: "x\(id)"), "part of a longer word is not an id")
    }

    func testManifestKeyGivesTheSameIDAsThePackage() throws {
        let header = try Crx3.parse(fixture())
        let key = try XCTUnwrap(header.rsaProofs.first { ChromeExtensionID.from(publicKey: $0.publicKey) == fixtureID }?.publicKey)
        XCTAssertEqual(ChromeExtensionID.from(manifestKey: key.base64EncodedString(options: .lineLength64Characters)), fixtureID)
        XCTAssertNil(ChromeExtensionID.from(manifestKey: "!!!"))
    }

    func testStoreURLs() {
        let download = ChromeWebStore.downloadURL(for: fixtureID).absoluteString
        XCTAssertTrue(download.hasPrefix("https://clients2.google.com/service/update2/crx?"))
        XCTAssertTrue(download.contains("acceptformat=crx3"))
        XCTAssertTrue(download.contains(fixtureID))
        let check = ChromeWebStore.updateCheckURL(for: fixtureID, installedVersion: "1.2.3").absoluteString
        XCTAssertTrue(check.contains("response=updatecheck"))
        XCTAssertTrue(check.contains("v%3D1.2.3") || check.contains("v=1.2.3"))
    }
}

/// Crafted archives, each aimed at a way a second reader of the same bytes
/// could disagree with the check -- all refused before anything is written.
final class ZipArchiveTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func refuses(_ zip: Data, _ expected: ZipArchiveError, line: UInt = #line) {
        let target = root.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try ZipArchive.extract(zip, into: target), line: line) {
            XCTAssertEqual($0 as? ZipArchiveError, expected, line: line)
        }
        let written = (try? FileManager.default.subpathsOfDirectory(atPath: target.path)) ?? []
        XCTAssertTrue(written.isEmpty, "nothing written: \(written)", line: line)
    }

    func testStoredEntriesExtractWithTheirFolders() throws {
        let zip = Self.zip([.file("manifest.json", "{}"), .directory("_locales/"), .file("_locales/en/messages.json", "hi")])
        let target = root.appendingPathComponent("out")
        try ZipArchive.extract(zip, into: target)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("_locales/en/messages.json")), "hi")
    }

    func testTraversalAndAbsoluteNamesAreRefused() {
        refuses(Self.zip([.file("ok.txt", ""), .file("../escape.txt", "x")]), .unsafeEntry("../escape.txt"))
        refuses(Self.zip([.file("/etc/evil", "x")]), .unsafeEntry("/etc/evil"))
        refuses(Self.zip([.file("a\\..\\..\\b", "x")]), .unsafeEntry("a\\..\\..\\b"))
        refuses(Self.zip([.file("a/./b", "x")]), .unsafeEntry("a/./b"))
        XCTAssertNoThrow(try ZipArchive.entries(in: Self.zip([.file("a..b/c", "")])))
    }

    /// A link then a file "through" it -- refused on the link, whatever
    /// system the entry claims made it.
    func testSymbolicLinkIsRefusedForAnyMadeBy() {
        for madeBy in [0, 3, 19] {
            let zip = Self.zip([.link("a", "/Users/Shared"), .file("a/x.plist", "payload")], madeBy: madeBy)
            refuses(zip, .symbolicLink("a"))
        }
    }

    func testDecoyEndRecordInTheCommentIsRefused() {
        let decoy = Self.zip([.file("manifest.json", "{}")])
        let real = Self.zip([.file("manifest.json", "{}")], comment: decoy.suffix(22))
        refuses(real, .notAZip)
    }

    func testTrailingBytesAfterTheCommentAreRefused() {
        refuses(Self.zip([.file("manifest.json", "{}")]) + Data([0, 1, 2]), .notAZip)
    }

    func testLocalNameThatDisagreesWithTheDirectoryIsRefused() {
        refuses(Self.zip([.file("manifest.json", "{}")], localNames: ["manifest.jsoX"]), .corrupt("manifest.json"))
    }

    func testDuplicateNamesIgnoringCaseAreRefused() {
        refuses(Self.zip([.file("manifest.json", "{}"), .file("Manifest.JSON", "{}")]), .duplicateEntry("Manifest.JSON"))
        refuses(Self.zip([.file("a", "x"), .file("a/b", "y")]), .duplicateEntry("a/b"))
    }

    func testBadCRCAndEncryptionAreRefused() {
        refuses(Self.zip([.file("manifest.json", "{}")], corruptCRC: true), .corrupt("manifest.json"))
        refuses(Self.zip([.file("manifest.json", "{}")], flags: 1), .unsupported("manifest.json"))
    }

    func testGarbageIsNotAZip() {
        XCTAssertThrowsError(try ZipArchive.entries(in: Data(repeating: 7, count: 100))) {
            XCTAssertEqual($0 as? ZipArchiveError, .notAZip)
        }
    }

    enum Item {
        case file(String, String)
        case directory(String)
        case link(String, String)
    }

    /// A stored (uncompressed) zip, with local headers, built by hand so each
    /// field can be bent.
    static func zip(_ items: [Item], madeBy: Int = 3, comment: Data = Data(), localNames: [String] = [],
                    corruptCRC: Bool = false, flags: Int = 0) -> Data {
        func u16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var body = Data()
        var central = Data()
        for (index, item) in items.enumerated() {
            let name: String, content: Data, mode: UInt32
            switch item {
            case .file(let n, let c): name = n; content = Data(c.utf8); mode = 0o100644
            case .directory(let n): name = n; content = Data(); mode = 0o040755
            case .link(let n, let target): name = n; content = Data(target.utf8); mode = 0o120777
            }
            let crc = ZipArchive.crc32(content) ^ (corruptCRC ? 1 : 0)
            let nameBytes = Data(name.utf8)
            let localName = Data((index < localNames.count ? localNames[index] : name).utf8)
            let offset = UInt32(body.count)
            body += u32(0x0403_4b50) + u16(20) + u16(flags) + u16(0) + u16(0) + u16(0)
            body += u32(crc) + u32(UInt32(content.count)) + u32(UInt32(content.count))
            body += u16(localName.count) + u16(0) + localName + content
            central += u32(0x0201_4b50) + u16(madeBy << 8 | 20) + u16(20) + u16(flags) + u16(0) + u16(0) + u16(0)
            central += u32(crc) + u32(UInt32(content.count)) + u32(UInt32(content.count))
            central += u16(nameBytes.count) + u16(0) + u16(0) + u16(0) + u16(0)
            central += u32(mode << 16) + u32(offset) + nameBytes
        }
        var zip = body
        let offset = zip.count
        zip += central
        zip += u32(0x0605_4b50) + u16(0) + u16(0) + u16(items.count) + u16(items.count)
        zip += u32(UInt32(central.count)) + u32(UInt32(offset)) + u16(comment.count) + comment
        return zip
    }
}

final class ChromeExtensionUpdateTests: XCTestCase {
    func testVersionOrderingIsNumeric() throws {
        func v(_ s: String) throws -> ChromeExtensionVersion { try XCTUnwrap(ChromeExtensionVersion(s)) }
        XCTAssertLessThan(try v("1.9"), try v("1.10"))
        XCTAssertLessThan(try v("2025.1.9.1"), try v("2025.1.10"))
        XCTAssertEqual(try v("2"), try v("2.0.0.0"))
        XCTAssertGreaterThan(try v("3.0"), try v("2.99.99.99"))
        XCTAssertNil(ChromeExtensionVersion("1.2.3.4.5"))
        XCTAssertNil(ChromeExtensionVersion("1.x"))
        XCTAssertNil(ChromeExtensionVersion("1..2"))
        XCTAssertNil(ChromeExtensionVersion("65536"))
        XCTAssertNil(ChromeExtensionVersion("1.01"))
        XCTAssertNil(ChromeExtensionVersion(""))
    }

    /// The shape the store actually answers with: an XML declaration whose
    /// own `version="1.0"` comes first, and `status="ok"` on `<app>`
    /// whether or not there is an update.
    func testNoUpdateIsNotMistakenForOne() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0" server="prod">\
        <daystart elapsed_days="7000" elapsed_seconds="100"/><app appid="ddkjiahejlhfcafbddmgiahcphecmpfh" cohort="1::" status="ok">\
        <updatecheck status="noupdate"/></app></gupdate>
        """
        let checks = ChromeExtensionUpdateCheck.parse(Data(xml.utf8))
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks.first?.status, "noupdate")
        XCTAssertNil(checks.first?.availableUpdate(over: "2025.1.1"))
    }

    func testNewerVersionIsAnUpdateAndOlderOrEqualIsNot() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">\
        <app appid="abc" status="ok"><updatecheck codebase="https://clients2.googleusercontent.com/crx/blobs/x.crx" \
        fp="1.hash" hash_sha256="00" protected="0" size="10" status="ok" version="1.10.0"/></app></gupdate>
        """
        let check = ChromeExtensionUpdateCheck.parse(Data(xml.utf8)).first
        XCTAssertEqual(check?.appID, "abc")
        XCTAssertEqual(check?.version, "1.10.0")
        XCTAssertEqual(check?.availableUpdate(over: "1.9.5")?.description, "1.10.0")
        XCTAssertNil(check?.availableUpdate(over: "1.10"))
        XCTAssertNil(check?.availableUpdate(over: "1.11"))
    }

    func testErrorStatusAndGarbageAreNoUpdate() {
        let xml = #"<?xml version="1.0"?><gupdate><app appid="abc" status="error-unknownApplication"><updatecheck status="error-unknownApplication"/></app></gupdate>"#
        XCTAssertNil(ChromeExtensionUpdateCheck.parse(Data(xml.utf8)).first?.availableUpdate(over: "1"))
        XCTAssertTrue(ChromeExtensionUpdateCheck.parse(Data("not xml".utf8)).isEmpty)
    }

    // MARK: - Grants

    func testGrantsFlagOnlyWhatIsNew() {
        let granted = WebExtensionGrants.make(permissions: ["storage", "tabs"], matchPatterns: ["https://example.com/*"])
        let same = WebExtensionGrants.make(permissions: ["tabs", "storage"], matchPatterns: ["https://example.com/*"])
        XCTAssertEqual(WebExtensionGrants.added(same, beyond: granted), [])
        let more = WebExtensionGrants.make(permissions: ["storage", "tabs", "cookies"], matchPatterns: ["https://example.com/*", "https://other.test/*"])
        XCTAssertEqual(WebExtensionGrants.added(more, beyond: granted), ["host:https://other.test/*", "perm:cookies"])
        let fewer = WebExtensionGrants.make(permissions: ["storage"], matchPatterns: [])
        XCTAssertEqual(WebExtensionGrants.added(fewer, beyond: granted), [])
    }

    func testAllHostsCoversAnyNewSite() {
        let granted = WebExtensionGrants.make(permissions: [], matchPatterns: ["<all_urls>"])
        let requested = WebExtensionGrants.make(permissions: [], matchPatterns: ["https://new.test/*"])
        XCTAssertEqual(WebExtensionGrants.added(requested, beyond: granted), [])
        XCTAssertEqual(WebExtensionGrants.permissions(in: ["perm:tabs", "host:x"]), ["tabs"])
        XCTAssertEqual(WebExtensionGrants.matchPatterns(in: ["perm:tabs", "host:x"]), ["x"])
    }

    func testListRoundTripsAndDailyCheck() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("installed.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertThrowsError(try InstalledWebExtensionList().save(to: url), "saving never creates the folder")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var list = InstalledWebExtensionList(extensions: [
            InstalledWebExtension(id: "pgmnddkfhcbihfijmfgancppilgkimei", source: .webStore, name: "Fixture Hello", version: "1.2.3", grants: ["perm:storage"], installedAt: now),
        ])
        XCTAssertTrue(list.isUpdateCheckDue(now: now))
        list.lastUpdateCheck = now
        try list.save(to: url)
        let loaded = InstalledWebExtensionList.load(from: url)
        XCTAssertEqual(loaded, list)
        XCTAssertFalse(loaded.isUpdateCheckDue(now: now.addingTimeInterval(3600)))
        XCTAssertTrue(loaded.isUpdateCheckDue(now: now.addingTimeInterval(21 * 3600)))
        XCTAssertTrue(loaded.isUpdateCheckDue(now: now.addingTimeInterval(-3600)), "a clock set back does not stop checks for good")
        XCTAssertEqual(InstalledWebExtensionList.load(from: url.appendingPathExtension("missing")), InstalledWebExtensionList())
    }
}
