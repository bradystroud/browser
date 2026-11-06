import Foundation

/// The parts of a WebAuthn attestation object that a browser exposes on
/// `AuthenticatorAttestationResponse` besides the object itself:
/// `getAuthenticatorData()`, `getPublicKeyAlgorithm()` and `getPublicKey()`
/// (DER SubjectPublicKeyInfo). The system passkey API returns only the raw
/// attestation object, so the browser derives the rest.
public struct WebAuthnAttestation: Equatable, Sendable {
    public let authenticatorData: Data
    public let publicKeyAlgorithm: Int
    /// Nil for a key type this does not convert (anything but EC2 P-256,
    /// Ed25519 and RSA), which `getPublicKey()` reports as null, as the
    /// spec allows.
    public let publicKey: Data?

    public init?(attestationObject: Data) {
        guard case .map(let entries)? = try? CBOR.decode(attestationObject),
              case .bytes(let authData)? = entries.first(where: { $0.key == .text("authData") })?.value
        else { return nil }
        // rpIdHash (32) | flags (1) | signCount (4) | AAGUID (16) | idLength (2) | id | COSE key
        guard authData.count >= 55, authData[authData.startIndex + 32] & 0x40 != 0 else { return nil }
        let base = authData.startIndex
        let idLength = Int(authData[base + 53]) << 8 | Int(authData[base + 54])
        let keyStart = base + 55 + idLength
        guard keyStart < authData.endIndex,
              case .map(let key)? = try? CBOR.decodePrefix(authData[keyStart...]).value
        else { return nil }
        func int(_ label: Int) -> Int? {
            if case .int(let v)? = key.first(where: { $0.key == .int(label) })?.value { return v }
            return nil
        }
        func bytes(_ label: Int) -> Data? {
            if case .bytes(let v)? = key.first(where: { $0.key == .int(label) })?.value { return v }
            return nil
        }
        guard let algorithm = int(3) else { return nil }
        self.authenticatorData = Data(authData)
        self.publicKeyAlgorithm = algorithm
        switch (int(1), int(-1)) {
        case (2?, 1?):  // EC2, P-256
            if let x = bytes(-2), let y = bytes(-3), x.count == 32, y.count == 32 {
                publicKey = DER.p256SubjectPublicKeyInfo(x: x, y: y)
            } else {
                publicKey = nil
            }
        case (1?, 6?):  // OKP, Ed25519
            publicKey = bytes(-2).flatMap { $0.count == 32 ? DER.ed25519SubjectPublicKeyInfo($0) : nil }
        case (3?, _):  // RSA
            if let n = bytes(-1), let e = bytes(-2) {
                publicKey = DER.rsaSubjectPublicKeyInfo(modulus: n, exponent: e)
            } else {
                publicKey = nil
            }
        default:
            publicKey = nil
        }
    }
}

/// Just enough CBOR (RFC 8949) to read an attestation object and a COSE key:
/// integers, byte and text strings, arrays, maps, and simple values. No
/// indefinite lengths, which neither may use (CTAP2 canonical CBOR).
indirect enum CBOR: Equatable, Sendable {
    case int(Int)
    case bytes(Data)
    case text(String)
    case array([CBOR])
    case map([(key: CBOR, value: CBOR)])
    case simple(UInt8)

    struct DecodeError: Error {}

    static func == (a: CBOR, b: CBOR) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y
        case (.bytes(let x), .bytes(let y)): return x == y
        case (.text(let x), .text(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.simple(let x), .simple(let y)): return x == y
        case (.map(let x), .map(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    static func decode(_ data: Data) throws -> CBOR {
        let (value, end) = try decodePrefix(data[...])
        guard end == data.endIndex else { throw DecodeError() }
        return value
    }

    /// One item from the start of `data`, and the index just after it.
    static func decodePrefix(_ data: Data.SubSequence, depth: Int = 0) throws -> (value: CBOR, end: Data.Index) {
        guard depth < 16, let first = data.first else { throw DecodeError() }
        var index = data.startIndex + 1
        let major = first >> 5, info = first & 0x1f
        func argument() throws -> UInt64 {
            switch info {
            case 0..<24: return UInt64(info)
            case 24...27:
                let size = 1 << Int(info - 24)
                guard data.endIndex - index >= size else { throw DecodeError() }
                let value = data[index..<index + size].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                index += size
                return value
            default: throw DecodeError()
            }
        }
        func take(_ count: UInt64) throws -> Data {
            guard count <= UInt64(data.endIndex - index) else { throw DecodeError() }
            let slice = Data(data[index..<index + Int(count)])
            index += Int(count)
            return slice
        }
        switch major {
        case 0:
            let v = try argument()
            guard v <= UInt64(Int.max) else { throw DecodeError() }
            return (.int(Int(v)), index)
        case 1:
            let v = try argument()
            guard v < UInt64(Int.max) else { throw DecodeError() }
            return (.int(-1 - Int(v)), index)
        case 2:
            return (.bytes(try take(try argument())), index)
        case 3:
            guard let text = String(data: try take(try argument()), encoding: .utf8) else { throw DecodeError() }
            return (.text(text), index)
        case 4:
            let count = try argument()
            guard count <= UInt64(data.endIndex - index) else { throw DecodeError() }
            var items: [CBOR] = []
            for _ in 0..<count {
                let (item, end) = try decodePrefix(data[index...], depth: depth + 1)
                items.append(item)
                index = end
            }
            return (.array(items), index)
        case 5:
            let count = try argument()
            guard count <= UInt64(data.endIndex - index) else { throw DecodeError() }
            var entries: [(key: CBOR, value: CBOR)] = []
            for _ in 0..<count {
                let (key, keyEnd) = try decodePrefix(data[index...], depth: depth + 1)
                let (value, valueEnd) = try decodePrefix(data[keyEnd...], depth: depth + 1)
                entries.append((key, value))
                index = valueEnd
            }
            return (.map(entries), index)
        case 7:
            guard info < 24 else { throw DecodeError() }
            return (.simple(info), index)
        default:
            throw DecodeError()
        }
    }
}

/// The three SubjectPublicKeyInfo shapes `getPublicKey()` returns.
enum DER {
    static func p256SubjectPublicKeyInfo(x: Data, y: Data) -> Data {
        // SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING 04||x||y }
        let prefix: [UInt8] = [
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00, 0x04,
        ]
        return Data(prefix) + x + y
    }

    static func ed25519SubjectPublicKeyInfo(_ key: Data) -> Data {
        Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00]) + key
    }

    static func rsaSubjectPublicKeyInfo(modulus: Data, exponent: Data) -> Data {
        let rsaKey = sequence(integer(modulus) + integer(exponent))
        let algorithm = sequence(Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00]))
        return sequence(algorithm + element(0x03, Data([0x00]) + rsaKey))
    }

    static func integer(_ magnitude: Data) -> Data {
        var bytes = Data(magnitude.drop(while: { $0 == 0 }))
        if bytes.isEmpty || bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return element(0x02, bytes)
    }

    static func sequence(_ content: Data) -> Data { element(0x30, content) }

    static func element(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var length = Data()
            var n = count
            while n > 0 { length.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
            out.append(0x80 | UInt8(length.count))
            out.append(length)
        }
        return out + content
    }
}
