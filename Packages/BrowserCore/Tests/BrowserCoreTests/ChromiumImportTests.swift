import CommonCrypto
import XCTest
@testable import BrowserCore

/// Every credential here is a made-up fixture. The known-answer vector was
/// produced outside CommonCrypto (Python's hashlib.pbkdf2_hmac for the key,
/// `openssl enc -aes-128-cbc` for the ciphertext), so these tests check the
/// derivation and decryption against an independent implementation rather
/// than against themselves.
final class ChromiumImportTests: XCTestCase {
    private let passphrase = Data("fixture-passphrase".utf8)
    /// PBKDF2-HMAC-SHA1("fixture-passphrase", "saltysalt", 1003, 16).
    private let derivedKeyHex = "ffd104a747415be79560021f94d29ea3"
    /// "correct horse" under that key, IV of sixteen spaces, PKCS#7.
    private let correctHorseCiphertextHex = "dcd9a2f60eb2f94b89bf0e7d2be2322f"

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try TestSupport.makeTempProfileDirectory()
    }

    override func tearDown() {
        TestSupport.removeQuietly(tempDir)
    }

    // MARK: - Helpers

    private func hexData(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private func v10(_ ciphertextHex: String) -> Data {
        Data("v10".utf8) + hexData(ciphertextHex)
    }

    /// Encrypts with the known-answer key, for cases the fixed vector does
    /// not cover.
    private func encrypt(_ plaintext: String, keyHex: String? = nil) -> Data {
        let key = [UInt8](hexData(keyHex ?? derivedKeyHex))
        let input = [UInt8](plaintext.utf8)
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let iv = [UInt8](repeating: 0x20, count: 16)
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &out, out.count, &moved)
        precondition(status == kCCSuccess)
        return Data("v10".utf8) + Data(out.prefix(moved))
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func makeLoginData(at url: URL, rows: [(origin: String, user: String, blob: Data, never: Bool)]) throws {
        let connection = try SQLiteConnection(path: url.path)
        try connection.execute("""
            CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_value VARCHAR,
            password_value BLOB, signon_realm VARCHAR NOT NULL, blacklisted_by_user INTEGER NOT NULL);
            """)
        for row in rows {
            try connection.execute("""
                INSERT INTO logins (origin_url, username_value, password_value, signon_realm, blacklisted_by_user)
                VALUES ('\(row.origin)', '\(row.user)', X'\(hex(row.blob))', '\(row.origin)', \(row.never ? 1 : 0));
                """)
        }
    }

    // MARK: - Key + decryption

    func testKnownAnswerVectorDecrypts() throws {
        let key = try XCTUnwrap(ChromiumSafeStorageKey(passphrase: passphrase))
        XCTAssertEqual(key.decrypt(v10(correctHorseCiphertextHex)), .password("correct horse"))
    }

    func testUnicodePasswordRoundTrips() throws {
        let key = try XCTUnwrap(ChromiumSafeStorageKey(passphrase: passphrase))
        XCTAssertEqual(key.decrypt(encrypt("pässwörd 🔑 with sixteen+ bytes")), .password("pässwörd 🔑 with sixteen+ bytes"))
    }

    func testWrongPassphraseFailsWithoutCrashing() throws {
        let key = try XCTUnwrap(ChromiumSafeStorageKey(passphrase: Data("not-the-passphrase".utf8)))
        XCTAssertEqual(key.decrypt(v10(correctHorseCiphertextHex)), .failed)
    }

    func testOtherVersionPrefixesAreUnsupported() throws {
        let key = try XCTUnwrap(ChromiumSafeStorageKey(passphrase: passphrase))
        XCTAssertEqual(key.decrypt(Data("v20".utf8) + hexData(correctHorseCiphertextHex)), .unsupportedFormat)
        XCTAssertEqual(key.decrypt(Data("v11".utf8) + Data(repeating: 7, count: 32)), .unsupportedFormat)
    }

    func testMalformedV10IsFailedNotCrash() throws {
        let key = try XCTUnwrap(ChromiumSafeStorageKey(passphrase: passphrase))
        XCTAssertEqual(key.decrypt(Data("v10".utf8)), .failed)
        XCTAssertEqual(key.decrypt(Data("v10".utf8) + Data([1, 2, 3])), .failed)
    }

    func testEmptyAndUnprefixedValues() throws {
        let key = try XCTUnwrap(ChromiumSafeStorageKey(passphrase: passphrase))
        XCTAssertEqual(key.decrypt(Data()), .empty)
        XCTAssertEqual(key.decrypt(Data("legacy-plain".utf8)), .password("legacy-plain"))
    }

    func testWipedKeyNoLongerDecrypts() throws {
        let key = try XCTUnwrap(ChromiumSafeStorageKey(passphrase: passphrase))
        key.wipe()
        XCTAssertEqual(key.decrypt(v10(correctHorseCiphertextHex)), .failed)
    }

    func testEmptyPassphraseIsRejected() {
        XCTAssertNil(ChromiumSafeStorageKey(passphrase: Data()))
    }

    // MARK: - Login Data

    func testReadsAndExtractsLoginDataCopy() throws {
        let source = tempDir.appendingPathComponent("Login Data")
        try makeLoginData(at: source, rows: [
            ("https://example.com/login", "alice", v10(correctHorseCiphertextHex), false),
            ("https://example.org/", "bob", encrypt("hunter2"), false),
            ("https://never.example/", "", Data(), true),
            ("https://federated.example/", "carol", Data(), false),
            ("https://newer.example/", "dave", Data("v20".utf8) + Data(repeating: 1, count: 48), false),
            ("https://otherkey.example/", "erin", encrypt("secret", keyHex: "00112233445566778899aabbccddeeff"), false),
        ])

        let rows = try ChromiumProfileReader.withCopiedDatabase(at: source) { path in
            XCTAssertNotEqual(path, source.path)
            return try ChromiumProfileReader.readLogins(fromCopiedDatabaseAt: path)
        }
        XCTAssertEqual(rows.count, 6)
        XCTAssertEqual(rows.filter(\.isNeverSave).count, 1)

        let key = try XCTUnwrap(ChromiumSafeStorageKey(passphrase: passphrase))
        let extraction = ChromiumPasswordExtractor.extract(rows: rows, key: key)
        XCTAssertEqual(extraction.entries, [
            PasswordCSVEntry(url: "https://example.com/login", username: "alice", password: "correct horse"),
            PasswordCSVEntry(url: "https://example.org/", username: "bob", password: "hunter2"),
        ])
        XCTAssertEqual(extraction.emptyCount, 1)
        XCTAssertEqual(extraction.undecryptableCount, 2)
    }

    func testCopiedDatabaseDirectoryIsRemovedAfterward() throws {
        let source = tempDir.appendingPathComponent("Login Data")
        try makeLoginData(at: source, rows: [])
        var copiedPath = ""
        _ = try ChromiumProfileReader.withCopiedDatabase(at: source) { path in
            copiedPath = path
            let permissions = try FileManager.default.attributesOfItem(
                atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path
            )[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o700)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: copiedPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: copiedPath).deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCopyIncludesWritesStillInTheLiveBrowsersWAL() throws {
        let source = tempDir.appendingPathComponent("Login Data")
        try makeLoginData(at: source, rows: [])
        // Held open, as the owning browser would, so nothing is checkpointed.
        let live = try SQLiteConnection(path: source.path)
        try live.execute("""
            INSERT INTO logins (origin_url, username_value, password_value, signon_realm, blacklisted_by_user)
            VALUES ('https://fresh.example/', 'frank', X'\(hex(encrypt("just saved")))', 'https://fresh.example/', 0);
            """)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path + "-wal"))

        let rows = try ChromiumProfileReader.withCopiedDatabase(at: source) {
            try ChromiumProfileReader.readLogins(fromCopiedDatabaseAt: $0)
        }
        XCTAssertEqual(rows.map(\.username), ["frank"])
        withExtendedLifetime(live) {}
    }

    func testAFailedReadIsRetriedOnceFromAFreshCopy() throws {
        let source = tempDir.appendingPathComponent("Login Data")
        try makeLoginData(at: source, rows: [])
        var paths: [String] = []
        let result = try ChromiumProfileReader.withCopiedDatabase(at: source) { path -> Int in
            paths.append(path)
            if paths.count == 1 { throw ChromiumProfileReader.ReadError.unexpectedFormat }
            return paths.count
        }
        XCTAssertEqual(result, 2)
        XCTAssertNotEqual(paths[0], paths[1])

        var attempts = 0
        XCTAssertThrowsError(try ChromiumProfileReader.withCopiedDatabase(at: source) { _ in
            attempts += 1
            throw ChromiumProfileReader.ReadError.unexpectedFormat
        })
        XCTAssertEqual(attempts, 2, "retried exactly once")
    }

    func testDerivingFromRawBytesMatchesDerivingFromData() throws {
        let key = try passphrase.withUnsafeBytes { try XCTUnwrap(ChromiumSafeStorageKey(passphraseBytes: $0)) }
        XCTAssertEqual(key.decrypt(v10(correctHorseCiphertextHex)), .password("correct horse"))
    }

    func testMissingSourceThrows() {
        XCTAssertThrowsError(try ChromiumProfileReader.withCopiedDatabase(at: tempDir.appendingPathComponent("nope")) { _ in })
    }

    func testNonLoginDatabaseThrowsUnexpectedFormat() throws {
        let path = tempDir.appendingPathComponent("other.db").path
        try SQLiteConnection(path: path).execute("CREATE TABLE unrelated (x INTEGER);")
        XCTAssertThrowsError(try ChromiumProfileReader.readLogins(fromCopiedDatabaseAt: path))
    }

    // MARK: - History

    func testReadsHistoryNewestFirstWebOnly() throws {
        let path = tempDir.appendingPathComponent("History").path
        let connection = try SQLiteConnection(path: path)
        try connection.execute("""
            CREATE TABLE urls (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR, hidden INTEGER DEFAULT 0 NOT NULL);
            CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL);
            INSERT INTO urls VALUES (1, 'https://example.com/', 'Example', 0);
            INSERT INTO urls VALUES (2, 'chrome://settings/', 'Settings', 0);
            INSERT INTO urls VALUES (3, 'https://hidden.example/', 'Hidden', 1);
            INSERT INTO visits VALUES (1, 1, 13000000000000000);
            INSERT INTO visits VALUES (2, 1, 13000000001000000);
            INSERT INTO visits VALUES (3, 2, 13000000002000000);
            INSERT INTO visits VALUES (4, 3, 13000000003000000);
            """)
        let visits = try ChromiumProfileReader.readVisits(fromCopiedDatabaseAt: path)
        XCTAssertEqual(visits.map(\.url), ["https://example.com/", "https://example.com/"])
        XCTAssertEqual(visits.first?.title, "Example")
        // 13_000_000_000 s after 1601-01-01 is 1_355_526_400 s after 1970.
        XCTAssertEqual(visits.last?.visitTime.timeIntervalSince1970 ?? 0, 1_355_526_400, accuracy: 0.001)
        XCTAssertEqual(try ChromiumProfileReader.readVisits(fromCopiedDatabaseAt: path, limit: 1).map(\.visitTime),
                       [visits[0].visitTime])
    }

    // MARK: - Bookmarks

    func testParsesBookmarksJSON() throws {
        let json = """
        {"roots": {
          "bookmark_bar": {"name": "Bookmarks bar", "type": "folder", "children": [
            {"type": "url", "name": "Example", "url": "https://example.com/"},
            {"type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)"},
            {"type": "folder", "name": "Work", "children": [
              {"type": "url", "name": "", "url": "https://work.example/"}
            ]},
            {"type": "folder", "name": "Empty", "children": []}
          ]},
          "other": {"name": "Other bookmarks", "type": "folder", "children": [
            {"type": "url", "name": "Other", "url": "http://other.example/"}
          ]},
          "synced": {"name": "Mobile bookmarks", "type": "folder", "children": []}
        }, "version": 1}
        """
        let nodes = try ChromiumProfileReader.parseBookmarks(data: Data(json.utf8))
        XCTAssertEqual(nodes, [
            .folder(title: "Bookmarks bar", isFavoritesBar: true, children: [
                .bookmark(title: "Example", url: "https://example.com/"),
                .folder(title: "Work", isFavoritesBar: false, children: [
                    .bookmark(title: "https://work.example/", url: "https://work.example/"),
                ]),
            ]),
            .folder(title: "Other bookmarks", isFavoritesBar: false, children: [
                .bookmark(title: "Other", url: "http://other.example/"),
            ]),
        ])
    }

    func testMalformedBookmarksThrow() {
        XCTAssertThrowsError(try ChromiumProfileReader.parseBookmarks(data: Data("{}".utf8)))
        XCTAssertThrowsError(try ChromiumProfileReader.parseBookmarks(data: Data("not json".utf8)))
    }

    // MARK: - Discovery

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    func testDiscoversProfilesFromLocalStateAndFolders() throws {
        let appSupport = tempDir!
        let root = appSupport.appendingPathComponent("Google/Chrome")
        try touch(root.appendingPathComponent("Default/Login Data"))
        try touch(root.appendingPathComponent("Profile 2/Bookmarks"))
        try touch(root.appendingPathComponent("Profile 10/History"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile 3"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("System Profile"), withIntermediateDirectories: true)
        let localState = """
        {"profile": {"info_cache": {
          "Profile 2": {"name": "Work"},
          "Default": {"name": "Personal"},
          "Profile 3": {"name": "Empty one"}
        }}}
        """
        try Data(localState.utf8).write(to: root.appendingPathComponent("Local State"))

        let chrome = ChromiumBrowser.known.first { $0.name == "Chrome" }!
        let profiles = ChromiumBrowserDiscovery.profiles(of: chrome, in: appSupport)
        XCTAssertEqual(profiles.map(\.directoryName), ["Default", "Profile 2", "Profile 10"])
        XCTAssertEqual(profiles.map(\.displayName), ["Personal", "Work", "Profile 10"])
        XCTAssertTrue(profiles[0].hasLoginData)
        XCTAssertFalse(profiles[1].hasLoginData)

        let installed = ChromiumBrowserDiscovery.installedBrowsers(in: appSupport)
        XCTAssertEqual(installed.map(\.browser.name), ["Chrome"])
    }

    func testFlatUserDataFolderIsOneProfile() throws {
        let appSupport = tempDir!
        let opera = ChromiumBrowser.known.first { $0.name == "Opera" }!
        try touch(appSupport.appendingPathComponent("com.operasoftware.Opera/Login Data"))
        let profiles = ChromiumBrowserDiscovery.profiles(of: opera, in: appSupport)
        XCTAssertEqual(profiles.map(\.displayName), ["Opera"])
        XCTAssertTrue(profiles[0].hasLoginData)
    }

    func testNeverTargetsThisAppsOwnCEFKeychainItem() {
        for browser in ChromiumBrowser.known {
            for item in browser.keychainItems {
                XCTAssertNotEqual(item.service, "Chromium Safe Storage", browser.name)
            }
        }
    }
}
