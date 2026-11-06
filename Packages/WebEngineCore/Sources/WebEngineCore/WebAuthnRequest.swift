import Foundation

/// The page side of a `navigator.credentials` passkey call, as the CEF
/// passkey script sends it, and the checks the browser must make before it
/// hands the request to the system.
///
/// The system API for browsers (`ASPublicKeyCredentialClientData`) trusts
/// the caller with the origin and the relying party: macOS signs whatever
/// origin and RP ID it is given. So the checks a browser engine would make
/// are made here, from the origin the engine reported for the frame
/// (`PageMessage.origin`), never from anything in the page's JSON.

public enum WebAuthnError: Error, Equatable, Sendable {
    /// The DOMException name the page's promise rejects with.
    case notAllowed(String)
    case security(String)
    case notSupported(String)
    case invalidState(String)
    case type(String)
    case abort(String)

    public var name: String {
        switch self {
        case .notAllowed: return "NotAllowedError"
        case .security: return "SecurityError"
        case .notSupported: return "NotSupportedError"
        case .invalidState: return "InvalidStateError"
        case .type: return "TypeError"
        case .abort: return "AbortError"
        }
    }

    public var message: String {
        switch self {
        case .notAllowed(let m), .security(let m), .notSupported(let m),
             .invalidState(let m), .type(let m), .abort(let m):
            return m
        }
    }
}

public enum WebAuthnRelyingParty {
    /// Whether `origin` may use WebAuthn at all: a secure origin with a
    /// domain name. `http://localhost` counts as secure, as in every browser.
    /// IP-address hosts have no valid RP ID.
    public static func originIsEligible(_ origin: WebOrigin) -> Bool {
        if isIPAddress(origin.host) { return false }
        if origin.scheme == "https" { return true }
        return origin.scheme == "http" && (origin.host == "localhost" || origin.host.hasSuffix(".localhost"))
    }

    /// The RP ID to use for `requested` (the page's `rpId` / `rp.id`, or nil
    /// for none) from `origin`, or the error the page gets. The RP ID must be
    /// the origin's host or a registrable-domain suffix of it, never a public
    /// suffix.
    public static func resolve(requested: String?, origin: WebOrigin, suffixes: PublicSuffixList) -> Result<String, WebAuthnError> {
        guard originIsEligible(origin) else {
            return .failure(.security("This origin cannot use passkeys."))
        }
        guard let host = PublicSuffixList.asciiDomain(origin.host) else {
            return .failure(.security("This origin cannot use passkeys."))
        }
        guard let requested else { return .success(host) }
        guard let rpId = PublicSuffixList.asciiDomain(requested), !isIPAddress(rpId) else {
            return .failure(.security("The relying party ID is not a valid domain."))
        }
        if rpId == host { return .success(rpId) }
        guard host.hasSuffix("." + rpId), !suffixes.isPublicSuffix(rpId) else {
            return .failure(.security("The relying party ID is not a registrable domain suffix of, nor equal to, the current domain."))
        }
        return .success(rpId)
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}

/// Base64url without padding, the encoding the script uses for every
/// BufferSource.
public enum Base64URL {
    public static func decode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard !s.contains("=") || s.hasSuffix("=") else { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct WebAuthnCredentialDescriptor: Decodable, Equatable, Sendable {
    public let id: String
    public let type: String?
    public let transports: [String]?
}

/// `navigator.credentials.get({publicKey})`.
public struct WebAuthnGetRequest: Decodable, Sendable {
    public struct Options: Decodable, Sendable {
        public let challenge: String
        public let rpId: String?
        public let timeout: Double?
        public let userVerification: String?
        public let allowCredentials: [WebAuthnCredentialDescriptor]?
    }
    public let requestToken: String?
    public let mediation: String?
    public let publicKey: Options
}

/// `navigator.credentials.create({publicKey})`.
public struct WebAuthnCreateRequest: Decodable, Sendable {
    public struct RelyingParty: Decodable, Sendable {
        public let id: String?
        public let name: String?
    }
    public struct User: Decodable, Sendable {
        public let id: String
        public let name: String?
        public let displayName: String?
    }
    public struct Parameter: Decodable, Sendable {
        public let type: String?
        public let alg: Int
    }
    public struct Selection: Decodable, Sendable {
        public let authenticatorAttachment: String?
        public let residentKey: String?
        public let requireResidentKey: Bool?
        public let userVerification: String?
    }
    public struct Extensions: Decodable, Sendable {
        public let credProps: Bool?
    }
    public struct Options: Decodable, Sendable {
        public let challenge: String
        public let rp: RelyingParty
        public let user: User
        public let pubKeyCredParams: [Parameter]?
        public let timeout: Double?
        public let excludeCredentials: [WebAuthnCredentialDescriptor]?
        public let authenticatorSelection: Selection?
        public let attestation: String?
        public let extensions: Extensions?
    }
    public let requestToken: String?
    public let mediation: String?
    public let publicKey: Options
}

/// A checked request: every byte string decoded, the RP ID resolved from
/// the engine's origin, and the choice of authenticators made.
public struct WebAuthnAssertionPlan: Equatable, Sendable {
    public let origin: String
    public let rpId: String
    public let challenge: Data
    public let allowCredentials: [Data]
    /// Transports for each entry of `allowCredentials`, for security keys.
    public let allowTransports: [[String]]
    public let userVerification: String
    public let timeout: TimeInterval
}

public struct WebAuthnRegistrationPlan: Equatable, Sendable {
    public let origin: String
    public let rpId: String
    public let challenge: Data
    public let userID: Data
    public let userName: String
    public let userDisplayName: String
    public let algorithms: [Int]
    public let excludeCredentials: [Data]
    public let userVerification: String
    public let residentKey: String
    public let attestation: String
    /// iCloud Keychain / phone passkeys. Off when the page asked for a
    /// security key only, or for no algorithm a passkey can use (ES256).
    public let offerPlatform: Bool
    /// External security keys. Off when the page asked for a platform
    /// authenticator only.
    public let offerSecurityKey: Bool
    public let wantsCredProps: Bool
    public let timeout: TimeInterval
}

/// What the page gets when the native path should not take a request at
/// all, so the page's own engine handles it as it did before: conditional
/// (autofill) and silent mediation have no system sheet to show.
public enum WebAuthnPlanResult<Plan: Equatable & Sendable>: Equatable, Sendable {
    case plan(Plan)
    case fallback
    case failure(WebAuthnError)
}

public enum WebAuthnPlanner {
    /// COSE ES256, the only algorithm iCloud Keychain passkeys use.
    public static let es256 = -7
    static let defaultAlgorithms = [-7, -257]
    static let defaultTimeout: TimeInterval = 300
    static let timeoutRange: ClosedRange<TimeInterval> = 15...600

    public static func plan(_ request: WebAuthnGetRequest, origin: WebOrigin, suffixes: PublicSuffixList) -> WebAuthnPlanResult<WebAuthnAssertionPlan> {
        if let mediation = request.mediation, mediation == "conditional" || mediation == "silent" {
            return .fallback
        }
        let options = request.publicKey
        let rpId: String
        switch WebAuthnRelyingParty.resolve(requested: options.rpId, origin: origin, suffixes: suffixes) {
        case .success(let id): rpId = id
        case .failure(let error): return .failure(error)
        }
        guard let challenge = Base64URL.decode(options.challenge) else {
            return .failure(.type("The challenge is not a valid BufferSource."))
        }
        var ids: [Data] = [], transports: [[String]] = []
        for descriptor in options.allowCredentials ?? [] where (descriptor.type ?? "public-key") == "public-key" {
            guard let id = Base64URL.decode(descriptor.id) else {
                return .failure(.type("A credential ID is not a valid BufferSource."))
            }
            ids.append(id)
            transports.append(descriptor.transports ?? [])
        }
        return .plan(WebAuthnAssertionPlan(
            origin: origin.serialized,
            rpId: rpId,
            challenge: challenge,
            allowCredentials: ids,
            allowTransports: transports,
            userVerification: userVerification(options.userVerification),
            timeout: timeout(options.timeout)))
    }

    public static func plan(_ request: WebAuthnCreateRequest, origin: WebOrigin, suffixes: PublicSuffixList) -> WebAuthnPlanResult<WebAuthnRegistrationPlan> {
        if let mediation = request.mediation, mediation == "conditional" || mediation == "silent" {
            return .fallback
        }
        let options = request.publicKey
        let rpId: String
        switch WebAuthnRelyingParty.resolve(requested: options.rp.id, origin: origin, suffixes: suffixes) {
        case .success(let id): rpId = id
        case .failure(let error): return .failure(error)
        }
        guard let challenge = Base64URL.decode(options.challenge) else {
            return .failure(.type("The challenge is not a valid BufferSource."))
        }
        guard let userID = Base64URL.decode(options.user.id), (1...64).contains(userID.count) else {
            return .failure(.type("user.id must be between 1 and 64 bytes."))
        }
        let params = options.pubKeyCredParams ?? []
        let algorithms = params.isEmpty
            ? defaultAlgorithms
            : params.filter { ($0.type ?? "public-key") == "public-key" }.map(\.alg)
        guard !algorithms.isEmpty else {
            return .failure(.notSupported("No supported credential type was requested."))
        }
        var excluded: [Data] = []
        for descriptor in options.excludeCredentials ?? [] where (descriptor.type ?? "public-key") == "public-key" {
            guard let id = Base64URL.decode(descriptor.id) else {
                return .failure(.type("A credential ID is not a valid BufferSource."))
            }
            excluded.append(id)
        }
        let selection = options.authenticatorSelection
        let attachment = selection?.authenticatorAttachment
        let offerPlatform = attachment != "cross-platform" && algorithms.contains(es256)
        let offerSecurityKey = attachment != "platform"
        guard offerPlatform || offerSecurityKey else {
            return .failure(.notSupported("No authenticator supports the requested algorithms."))
        }
        let residentKey = selection?.residentKey
            ?? ((selection?.requireResidentKey ?? false) ? "required" : "discouraged")
        let name = options.user.name ?? ""
        return .plan(WebAuthnRegistrationPlan(
            origin: origin.serialized,
            rpId: rpId,
            challenge: challenge,
            userID: userID,
            userName: name,
            userDisplayName: options.user.displayName ?? name,
            algorithms: algorithms,
            excludeCredentials: excluded,
            userVerification: userVerification(selection?.userVerification),
            residentKey: ["required", "preferred", "discouraged"].contains(residentKey) ? residentKey : "discouraged",
            attestation: ["none", "indirect", "direct", "enterprise"].contains(options.attestation ?? "none") ? (options.attestation ?? "none") : "none",
            offerPlatform: offerPlatform,
            offerSecurityKey: offerSecurityKey,
            wantsCredProps: options.extensions?.credProps ?? false,
            timeout: timeout(options.timeout)))
    }

    static func userVerification(_ value: String?) -> String {
        guard let value, ["required", "preferred", "discouraged"].contains(value) else { return "preferred" }
        return value
    }

    /// The page's timeout in milliseconds, kept inside the range Chromium
    /// itself allows, so a page can neither hold the sheet open for ever nor
    /// close it before the user can answer.
    static func timeout(_ milliseconds: Double?) -> TimeInterval {
        guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return defaultTimeout }
        return min(max(milliseconds / 1000, timeoutRange.lowerBound), timeoutRange.upperBound)
    }
}
