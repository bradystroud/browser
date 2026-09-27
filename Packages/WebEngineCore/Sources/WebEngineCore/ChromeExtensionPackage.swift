// Portions of this file are adapted from Search (Sources/Search/Crx.swift),
// https://github.com/driceroland/Search, used under the MIT License:
//
//   MIT License
//
//   Copyright (c) 2026 Office Commun
//
//   Permission is hereby granted, free of charge, to any person obtaining a copy
//   of this software and associated documentation files (the "Software"), to deal
//   in the Software without restriction, including without limitation the rights
//   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//   copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions:
//
//   The above copyright notice and this permission notice shall be included in all
//   copies or substantial portions of the Software.
//
//   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//   SOFTWARE.

import CryptoKit
import Foundation
import Security

/// A Chrome extension's id is not a name anybody chose: it is the first
/// sixteen bytes of the SHA-256 of its RSA public key (DER
/// SubjectPublicKeyInfo), written one nibble per letter, `a` (0) to `p` (15).
/// That is what lets a downloaded package be checked against the id that was
/// asked for -- see `Crx3.verifiedArchive`.
public enum ChromeExtensionID {
    public static func isValid(_ id: String) -> Bool {
        id.count == 32 && id.utf8.allSatisfy { $0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "p") }
    }

    public static func letters(_ bytes: some Sequence<UInt8>) -> String {
        String(bytes.flatMap { [$0 >> 4, $0 & 0x0f] }.map { Character(UnicodeScalar(UInt8(ascii: "a") + $0)) })
    }

    public static func from(publicKey spki: Data) -> String {
        letters(SHA256.hash(data: spki).prefix(16))
    }

    /// A manifest's `"key"` field: the base64 public key a developer pins so
    /// an unpacked copy keeps its published id.
    public static func from(manifestKey base64: String) -> String? {
        let compact = base64.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let key = Data(base64Encoded: compact), !key.isEmpty else { return nil }
        return from(publicKey: key)
    }

    /// What Chrome calls an unpacked extension that pins no key: the hash of
    /// the folder's absolute path, so the same folder keeps its id (and with
    /// it its storage) across reloads and relaunches.
    public static func fromUnpackedPath(_ path: String) -> String {
        letters(SHA256.hash(data: Data(path.utf8)).prefix(16))
    }

    /// Thirty-two letters `a`-`p` standing on their own anywhere in `text` --
    /// a bare id, a chromewebstore.google.com link, an old
    /// chrome.google.com/webstore link.
    public static func find(in text: String) -> String? {
        let lowered = text.lowercased()
        let pattern = try! NSRegularExpression(pattern: "(?<![a-z0-9])([a-p]{32})(?![a-z0-9])")
        let range = NSRange(lowered.startIndex..., in: lowered)
        guard let match = pattern.firstMatch(in: lowered, range: range),
              let found = Range(match.range(at: 1), in: lowered)
        else { return nil }
        return String(lowered[found])
    }
}

/// The Chrome Web Store's public update service -- the same endpoint every
/// Chromium browser asks for an extension's package and for its updates.
public enum ChromeWebStore {
    /// The Chrome version the store is told it is serving. Some extensions
    /// declare a `minimum_chrome_version`, and the store withholds them from
    /// a browser reporting anything older.
    public static let reportedChromeVersion = "140.0.0.0"

    public static let endpoint = "https://clients2.google.com/service/update2/crx"

    public static func downloadURL(for id: String) -> URL {
        var parts = URLComponents(string: endpoint)!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: reportedChromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        return parts.url!
    }

    public static func updateCheckURL(for id: String, installedVersion: String) -> URL {
        var parts = URLComponents(string: endpoint)!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "updatecheck"),
            URLQueryItem(name: "prodversion", value: reportedChromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&v=\(installedVersion)&uc"),
        ]
        return parts.url!
    }
}

public enum Crx3Error: Error, Equatable, LocalizedError {
    case notACrx
    case unsupportedFormatVersion(UInt32)
    case malformedHeader
    /// The header's signed id is not the id that was asked for.
    case idMismatch(expected: String, found: String)
    /// No proof in the header is by the key the id is made from, or the one
    /// that is does not verify over the archive.
    case signatureInvalid

    public var errorDescription: String? {
        switch self {
        case .notACrx: return "The download is not a Chrome extension package."
        case .unsupportedFormatVersion(let version): return "The extension package uses an unsupported format (CRX\(version))."
        case .malformedHeader: return "The extension package's header is damaged."
        case .idMismatch(let expected, let found): return "The package is for extension \(found), not \(expected)."
        case .signatureInvalid: return "The extension package's signature does not verify."
        }
    }
}

/// The CRX3 package format: `Cr24`, a little-endian format version (3), a
/// little-endian header length, a protobuf `CrxFileHeader`, then the zip.
///
/// The check that matters: the header must carry an RSA proof whose public
/// key hashes to the requested id and whose signature holds over the signed
/// header data and the whole zip. A package altered in transit, or passed off
/// under another extension's id, fails one or the other. The Web Store adds a
/// proof by its own key too; that one is allowed but is not the one that
/// counts.
public enum Crx3 {
    /// Protobuf field numbers in `CrxFileHeader` / `AsymmetricKeyProof` /
    /// `SignedData` (components/crx_file/crx3.proto).
    private enum Field {
        static let sha256WithRSA = 2
        static let signedHeaderData = 10000
        static let proofPublicKey = 1
        static let proofSignature = 2
        static let signedCrxID = 1
    }

    public struct Header {
        public let signedHeaderData: Data
        public let crxID: Data
        public let rsaProofs: [(publicKey: Data, signature: Data)]
        public let archive: Data
    }

    public static func parse(_ crx: Data) throws -> Header {
        let bytes = [UInt8](crx)
        guard bytes.count >= 12, Array(bytes[0..<4]) == Array("Cr24".utf8) else { throw Crx3Error.notACrx }
        let version = le32(bytes, 4)
        guard version == 3 else { throw Crx3Error.unsupportedFormatVersion(version) }
        let headerSize = Int(le32(bytes, 8))
        guard headerSize <= bytes.count - 12 else { throw Crx3Error.malformedHeader }
        let header = Array(bytes[12..<(12 + headerSize)])
        let archive = Data(bytes[(12 + headerSize)...])

        guard let fields = protobufLengthDelimitedFields(header) else { throw Crx3Error.malformedHeader }
        guard let signedHeader = fields.first(where: { $0.field == Field.signedHeaderData })?.value,
              let signedFields = protobufLengthDelimitedFields(signedHeader),
              let crxID = signedFields.first(where: { $0.field == Field.signedCrxID })?.value
        else { throw Crx3Error.malformedHeader }

        var proofs: [(Data, Data)] = []
        for proof in fields where proof.field == Field.sha256WithRSA {
            guard let parts = protobufLengthDelimitedFields(proof.value),
                  let key = parts.first(where: { $0.field == Field.proofPublicKey })?.value,
                  let signature = parts.first(where: { $0.field == Field.proofSignature })?.value
            else { continue }
            proofs.append((Data(key), Data(signature)))
        }
        return Header(signedHeaderData: Data(signedHeader), crxID: Data(crxID), rsaProofs: proofs, archive: archive)
    }

    /// The zip inside `crx`, once its header has been checked against
    /// `expectedID` as described on the type.
    public static func verifiedArchive(_ crx: Data, expectedID: String) throws -> Data {
        let header = try parse(crx)
        let signedID = ChromeExtensionID.letters(header.crxID)
        guard signedID == expectedID else { throw Crx3Error.idMismatch(expected: expectedID, found: signedID) }

        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        var length = UInt32(header.signedHeaderData.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(header.signedHeaderData)
        message.append(header.archive)

        let owned = header.rsaProofs.contains { proof in
            ChromeExtensionID.from(publicKey: proof.publicKey) == expectedID
                && verifyRSA(spki: proof.publicKey, signature: proof.signature, message: message)
        }
        guard owned else { throw Crx3Error.signatureInvalid }
        return header.archive
    }

    // MARK: - Pieces

    private static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    /// Only length-delimited fields are returned (all a CRX header holds);
    /// varint and fixed-width fields are skipped. Nil for bytes that are not
    /// a well-formed message.
    static func protobufLengthDelimitedFields<C: Collection>(_ input: C) -> [(field: Int, value: [UInt8])]? where C.Element == UInt8 {
        let b = Array(input)
        var out: [(Int, [UInt8])] = []
        var i = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]
                i += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return nil }
            let field = Int(truncatingIfNeeded: key >> 3)
            switch key & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 1:
                guard b.count - i >= 8 else { return nil }
                i += 8
            case 2:
                guard let length = varint(), length <= UInt64(b.count - i) else { return nil }
                let end = i + Int(length)
                out.append((field, Array(b[i..<end])))
                i = end
            case 5:
                guard b.count - i >= 4 else { return nil }
                i += 4
            default:
                return nil
            }
        }
        return out
    }

    /// An RSA SubjectPublicKeyInfo (what Chrome writes) against a PKCS#1
    /// v1.5 SHA-256 signature.
    static func verifyRSA(spki: Data, signature: Data, message: Data) -> Bool {
        var format = SecExternalFormat.formatOpenSSL
        var type = SecExternalItemType.itemTypePublicKey
        var items: CFArray?
        guard SecItemImport(spki as CFData, nil, &format, &type, [], nil, nil, &items) == errSecSuccess,
              let first = (items as? [AnyObject])?.first,
              CFGetTypeID(first) == SecKeyGetTypeID()
        else { return false }
        let key = first as! SecKey
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }
}
