import XCTest
@testable import WebEngineCore

final class PublicSuffixListTests: XCTestCase {
    /// The real list the app ships, so these tests also catch a broken copy.
    static let shipped: PublicSuffixList = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Passkeys/public_suffix_list.dat")
        return PublicSuffixList(datText: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }()

    func testShippedListLoads() {
        XCTAssertFalse(Self.shipped.isEmpty)
    }

    func testIcannRules() {
        let list = Self.shipped
        XCTAssertEqual(list.publicSuffix(of: "www.example.com"), "com")
        XCTAssertEqual(list.publicSuffix(of: "login.contoso.com.au"), "com.au")
        XCTAssertTrue(list.isPublicSuffix("com.au"))
        XCTAssertFalse(list.isPublicSuffix("contoso.com.au"))
        XCTAssertTrue(list.isPublicSuffix("co.uk"))
    }

    func testPrivateRulesCount() {
        XCTAssertTrue(Self.shipped.isPublicSuffix("github.io"))
        XCTAssertFalse(Self.shipped.isPublicSuffix("someone.github.io"))
    }

    func testWildcardAndExceptionRules() {
        let list = PublicSuffixList(datText: "*.ck\n!www.ck\n// comment\ncom\n")
        XCTAssertTrue(list.isPublicSuffix("anything.ck"))
        XCTAssertFalse(list.isPublicSuffix("www.ck"))
        XCTAssertEqual(list.publicSuffix(of: "a.b.ck"), "b.ck")
        XCTAssertEqual(list.publicSuffix(of: "www.ck"), "ck")
        XCTAssertEqual(list.publicSuffix(of: "x.unknowntld"), "unknowntld")
    }

    func testUnicodeRulesMatchPunycodeHosts() {
        XCTAssertEqual(Punycode.encode("bücher"), "bcher-kva")
        XCTAssertEqual(Punycode.encode("公司"), "55qx5d")
        // 公司.cn is on the list in Unicode; engines report hosts in punycode.
        XCTAssertTrue(Self.shipped.isPublicSuffix("xn--55qx5d.cn"))
        XCTAssertTrue(Self.shipped.isPublicSuffix("公司.cn"))
    }
}

final class WebAuthnRelyingPartyTests: XCTestCase {
    let list = PublicSuffixListTests.shipped

    func origin(_ s: String) -> WebOrigin { WebOrigin(urlString: s)! }

    func testDefaultsToTheOriginHost() {
        XCTAssertEqual(try WebAuthnRelyingParty.resolve(requested: nil, origin: origin("https://login.example.com"), suffixes: list).get(), "login.example.com")
    }

    func testAllowsARegistrableParent() {
        XCTAssertEqual(try WebAuthnRelyingParty.resolve(requested: "example.com", origin: origin("https://login.example.com"), suffixes: list).get(), "example.com")
        XCTAssertEqual(try WebAuthnRelyingParty.resolve(requested: "Example.COM", origin: origin("https://login.example.com"), suffixes: list).get(), "example.com")
    }

    func testRefusesAnotherSite() {
        XCTAssertEqual(WebAuthnRelyingParty.resolve(requested: "google.com", origin: origin("https://evil.com"), suffixes: list).failureName, "SecurityError")
        // A suffix match that is not on a label boundary.
        XCTAssertEqual(WebAuthnRelyingParty.resolve(requested: "ample.com", origin: origin("https://example.com"), suffixes: list).failureName, "SecurityError")
        // A child of the origin.
        XCTAssertEqual(WebAuthnRelyingParty.resolve(requested: "a.example.com", origin: origin("https://example.com"), suffixes: list).failureName, "SecurityError")
    }

    func testRefusesPublicSuffixes() {
        XCTAssertEqual(WebAuthnRelyingParty.resolve(requested: "com", origin: origin("https://example.com"), suffixes: list).failureName, "SecurityError")
        XCTAssertEqual(WebAuthnRelyingParty.resolve(requested: "com.au", origin: origin("https://contoso.com.au"), suffixes: list).failureName, "SecurityError")
        // A private-registry suffix: one GitHub Pages user must not reach another's.
        XCTAssertEqual(WebAuthnRelyingParty.resolve(requested: "github.io", origin: origin("https://evil.github.io"), suffixes: list).failureName, "SecurityError")
    }

    func testOriginEligibility() {
        XCTAssertEqual(WebAuthnRelyingParty.resolve(requested: nil, origin: origin("http://example.com"), suffixes: list).failureName, "SecurityError")
        XCTAssertEqual(try WebAuthnRelyingParty.resolve(requested: nil, origin: origin("http://localhost:3000"), suffixes: list).get(), "localhost")
        XCTAssertEqual(WebAuthnRelyingParty.resolve(requested: nil, origin: origin("https://127.0.0.1"), suffixes: list).failureName, "SecurityError")
        XCTAssertEqual(WebAuthnRelyingParty.resolve(requested: nil, origin: origin("https://[::1]"), suffixes: list).failureName, "SecurityError")
    }
}

final class WebAuthnPlannerTests: XCTestCase {
    let list = PublicSuffixListTests.shipped
    let site = WebOrigin(urlString: "https://login.example.com")!

    func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        try! JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    func testBase64URLRoundTrip() {
        let bytes = Data([0xfb, 0xff, 0x00, 0x3e, 0x3f])
        XCTAssertEqual(Base64URL.encode(bytes), "-_8APj8")
        XCTAssertEqual(Base64URL.decode("-_8APj8"), bytes)
        XCTAssertNil(Base64URL.decode("a=b"))
    }

    func testAssertionPlan() {
        let request = decode(WebAuthnGetRequest.self, #"""
        {"type":"webauthnGet","publicKey":{"challenge":"AAEC","rpId":"example.com","timeout":1000,
         "allowCredentials":[{"id":"BAU","type":"public-key","transports":["usb"]}]}}
        """#)
        guard case .plan(let plan) = WebAuthnPlanner.plan(request, origin: site, suffixes: list) else { return XCTFail() }
        XCTAssertEqual(plan.rpId, "example.com")
        XCTAssertEqual(plan.origin, "https://login.example.com")
        XCTAssertEqual(plan.challenge, Data([0, 1, 2]))
        XCTAssertEqual(plan.allowCredentials, [Data([4, 5])])
        XCTAssertEqual(plan.allowTransports, [["usb"]])
        XCTAssertEqual(plan.userVerification, "preferred")
        // 1 s is clamped up so the user has time to answer.
        XCTAssertEqual(plan.timeout, 15)
    }

    func testConditionalMediationFallsBack() {
        let request = decode(WebAuthnGetRequest.self, #"{"mediation":"conditional","publicKey":{"challenge":"AAEC"}}"#)
        XCTAssertEqual(WebAuthnPlanner.plan(request, origin: site, suffixes: list), .fallback)
    }

    func testAssertionRefusesAnotherSitesRPID() {
        let request = decode(WebAuthnGetRequest.self, #"{"publicKey":{"challenge":"AAEC","rpId":"google.com"}}"#)
        XCTAssertEqual(WebAuthnPlanner.plan(request, origin: site, suffixes: list), .failure(.security("The relying party ID is not a registrable domain suffix of, nor equal to, the current domain.")))
    }

    func testRegistrationPlan() {
        let request = decode(WebAuthnCreateRequest.self, #"""
        {"publicKey":{"challenge":"AAEC","rp":{"name":"Example"},"user":{"id":"AQ","name":"brady","displayName":"Brady"},
         "pubKeyCredParams":[{"type":"public-key","alg":-7},{"type":"public-key","alg":-257}],
         "authenticatorSelection":{"residentKey":"required","userVerification":"required"},
         "excludeCredentials":[{"id":"BAU","type":"public-key"}],"extensions":{"credProps":true}}}
        """#)
        guard case .plan(let plan) = WebAuthnPlanner.plan(request, origin: site, suffixes: list) else { return XCTFail() }
        XCTAssertEqual(plan.rpId, "login.example.com")
        XCTAssertEqual(plan.userID, Data([1]))
        XCTAssertEqual(plan.userDisplayName, "Brady")
        XCTAssertEqual(plan.algorithms, [-7, -257])
        XCTAssertEqual(plan.excludeCredentials, [Data([4, 5])])
        XCTAssertEqual(plan.residentKey, "required")
        XCTAssertEqual(plan.attestation, "none")
        XCTAssertTrue(plan.offerPlatform)
        XCTAssertTrue(plan.offerSecurityKey)
        XCTAssertTrue(plan.wantsCredProps)
    }

    func testRegistrationAuthenticatorChoice() {
        let securityKeyOnly = decode(WebAuthnCreateRequest.self, #"""
        {"publicKey":{"challenge":"AA","rp":{},"user":{"id":"AQ"},"authenticatorSelection":{"authenticatorAttachment":"cross-platform"}}}
        """#)
        guard case .plan(let a) = WebAuthnPlanner.plan(securityKeyOnly, origin: site, suffixes: list) else { return XCTFail() }
        XCTAssertFalse(a.offerPlatform)
        XCTAssertTrue(a.offerSecurityKey)

        // RS256 only: iCloud Keychain cannot make that key, a security key can.
        let rsaOnly = decode(WebAuthnCreateRequest.self, #"""
        {"publicKey":{"challenge":"AA","rp":{},"user":{"id":"AQ"},"pubKeyCredParams":[{"type":"public-key","alg":-257}]}}
        """#)
        guard case .plan(let b) = WebAuthnPlanner.plan(rsaOnly, origin: site, suffixes: list) else { return XCTFail() }
        XCTAssertFalse(b.offerPlatform)
        XCTAssertTrue(b.offerSecurityKey)

        let impossible = decode(WebAuthnCreateRequest.self, #"""
        {"publicKey":{"challenge":"AA","rp":{},"user":{"id":"AQ"},"pubKeyCredParams":[{"type":"public-key","alg":-257}],
         "authenticatorSelection":{"authenticatorAttachment":"platform"}}}
        """#)
        XCTAssertEqual(WebAuthnPlanner.plan(impossible, origin: site, suffixes: list), .failure(.notSupported("No authenticator supports the requested algorithms.")))
    }

    func testRegistrationRejectsBadUserID() {
        let long = Base64URL.encode(Data(repeating: 1, count: 65))
        let request = decode(WebAuthnCreateRequest.self, #"{"publicKey":{"challenge":"AA","rp":{},"user":{"id":"\#(long)"}}}"#)
        XCTAssertEqual(WebAuthnPlanner.plan(request, origin: site, suffixes: list), .failure(.type("user.id must be between 1 and 64 bytes.")))
    }
}

private extension Result where Failure == WebAuthnError {
    var failureName: String? {
        if case .failure(let error) = self { return error.name }
        return nil
    }
}

import CryptoKit

final class WebAuthnAttestationTests: XCTestCase {
    /// A CTAP2 "none" attestation object around a real P-256 key.
    func attestationObject(x: Data, y: Data, credentialID: Data) -> (object: Data, authData: Data) {
        var cose = Data([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01])  // {1: 2, 3: -7, -1: 1,
        cose += Data([0x21, 0x58, 0x20]) + x                           //  -2: x,
        cose += Data([0x22, 0x58, 0x20]) + y                           //  -3: y}
        var authData = Data(repeating: 0xaa, count: 32)                // rpIdHash
        authData += Data([0x45])                                       // UP | UV | AT
        authData += Data([0, 0, 0, 0])                                 // signCount
        authData += Data(repeating: 0, count: 16)                      // AAGUID
        authData += Data([0, UInt8(credentialID.count)]) + credentialID + cose
        var object = Data([0xa3])
        object += Data([0x63]) + Data("fmt".utf8) + Data([0x64]) + Data("none".utf8)
        object += Data([0x67]) + Data("attStmt".utf8) + Data([0xa0])
        object += Data([0x68]) + Data("authData".utf8) + Data([0x58, UInt8(authData.count)]) + authData
        return (object, authData)
    }

    func testReadsAuthenticatorDataAndP256Key() {
        let key = P256.Signing.PrivateKey().publicKey
        let raw = key.rawRepresentation
        let built = attestationObject(x: raw.prefix(32), y: raw.suffix(32), credentialID: Data([1, 2, 3, 4]))
        let parsed = WebAuthnAttestation(attestationObject: built.object)
        XCTAssertEqual(parsed?.authenticatorData, built.authData)
        XCTAssertEqual(parsed?.publicKeyAlgorithm, -7)
        XCTAssertEqual(parsed?.publicKey, key.derRepresentation)
    }

    func testRejectsTruncatedInput() {
        let raw = P256.Signing.PrivateKey().publicKey.rawRepresentation
        let built = attestationObject(x: raw.prefix(32), y: raw.suffix(32), credentialID: Data([9]))
        XCTAssertNil(WebAuthnAttestation(attestationObject: built.object.dropLast(10)))
        XCTAssertNil(WebAuthnAttestation(attestationObject: Data([0xa1, 0x60])))
    }

    func testRSASubjectPublicKeyInfoIsDER() {
        let spki = DER.rsaSubjectPublicKeyInfo(modulus: Data(repeating: 0xc1, count: 256), exponent: Data([1, 0, 1]))
        let key = SecKeyCreateWithData(spki.dropFirst(24) as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
        ] as CFDictionary, nil)
        XCTAssertEqual(spki.prefix(4), Data([0x30, 0x82, 0x01, 0x22]))
        XCTAssertNotNil(key)
    }
}
