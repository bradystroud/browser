import Foundation
import XCTest
@testable import WebEngineCore

final class CertificateExceptionsTests: XCTestCase {
    func testFingerprintIsLowercaseHexSHA256() {
        // SHA-256 of the empty input.
        XCTAssertEqual(CertificateExceptions.fingerprint(ofDER: Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testTrustsOnlyTheExactCertificateForTheExactHost() {
        var exceptions = CertificateExceptions()
        exceptions.trust(host: "Manage.Example.Family", fingerprint: "AB12")
        XCTAssertTrue(exceptions.trusts(host: "manage.example.family", fingerprint: "ab12"))
        XCTAssertFalse(exceptions.trusts(host: "manage.example.family", fingerprint: "cd34"))
        XCTAssertFalse(exceptions.trusts(host: "example.family", fingerprint: "ab12"))
        XCTAssertFalse(exceptions.trusts(host: "other.manage.example.family", fingerprint: "ab12"))
    }

    func testKeepsEveryTrustedCertificateOnceAndRemovesByHost() {
        var exceptions = CertificateExceptions()
        exceptions.trust(host: "a.test", fingerprint: "01")
        exceptions.trust(host: "a.test", fingerprint: "01")
        exceptions.trust(host: "a.test", fingerprint: "02")
        XCTAssertEqual(exceptions.hosts["a.test"], ["01", "02"])
        XCTAssertTrue(exceptions.hasException(host: "A.TEST"))
        exceptions.remove(host: "A.test")
        XCTAssertFalse(exceptions.hasException(host: "a.test"))
        XCTAssertTrue(exceptions.hosts.isEmpty)
    }

    func testIgnoresEmptyValues() {
        var exceptions = CertificateExceptions()
        exceptions.trust(host: "", fingerprint: "01")
        exceptions.trust(host: "a.test", fingerprint: "")
        XCTAssertTrue(exceptions.hosts.isEmpty)
    }

    func testRoundTripsThroughJSON() throws {
        var exceptions = CertificateExceptions()
        exceptions.trust(host: "a.test", fingerprint: "01")
        let data = try JSONEncoder().encode(exceptions)
        XCTAssertEqual(try JSONDecoder().decode(CertificateExceptions.self, from: data), exceptions)
    }
}
