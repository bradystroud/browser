import AppKit
import AuthenticationServices
import Security

/// Answers `PasskeyPageScript`'s passkey requests from CEF tabs with the
/// system passkey sheet (Touch ID / iCloud Keychain, a phone, a security
/// key), through the AuthenticationServices API Apple provides for web
/// browsers.
///
/// That API signs whatever origin and relying party it is handed -- the
/// `com.apple.developer.web-browser.public-key-credential` entitlement is
/// Apple trusting the browser to have checked them. So this class acts only
/// on the origin `PageMessageDispatcher` derived from the engine, and only
/// on the RP ID `WebAuthnPlanner` accepted for it. It never reads an origin
/// from the request.
///
/// Off entirely (the script is never injected, so Chromium's own QR and
/// security-key flow stays) without the entitlement -- an ad-hoc build --
/// before macOS 13.5, or when the bundled Public Suffix List is missing.
final class PlatformPasskeyBroker: NSObject {
    static let shared = PlatformPasskeyBroker()

    private var started = false
    private lazy var suffixes: PublicSuffixList? = Self.loadSuffixList()
    private var pending: Pending?
    /// True while macOS asks the user whether this app may use their
    /// passkeys. Holds off a second request, as `pending` does.
    private var awaitingPermission = false

    private final class Pending {
        let token: String?
        let requestId: Int64
        weak var tab: Tab?
        let window: NSWindow
        let controller: ASAuthorizationController
        let isCreate: Bool
        let wantsCredProps: Bool
        var timer: Timer?

        init(token: String?, requestId: Int64, tab: Tab, window: NSWindow, controller: ASAuthorizationController, isCreate: Bool, wantsCredProps: Bool) {
            self.token = token
            self.requestId = requestId
            self.tab = tab
            self.window = window
            self.controller = controller
            self.isCreate = isCreate
            self.wantsCredProps = wantsCredProps
        }
    }

    private struct TokenPayload: Decodable { let requestToken: String? }

    /// Whether CEF tabs get `PasskeyPageScript`.
    var isAvailable: Bool {
        guard #available(macOS 13.5, *) else { return false }
        return Self.hasBrowserPasskeyEntitlement && suffixes != nil
    }

    func activate() {
        guard !started else { return }
        started = true
        PageMessageDispatcher.shared.activate()
        PageMessageDispatcher.shared.register(types: ["webauthnGet", "webauthnCreate", "webauthnCancel"]) { [weak self] (message: PageMessage) in
            self?.handle(message)
        }
    }

    private func handle(_ message: PageMessage) {
        let tab = message.tab
        if message.type == "webauthnCancel" {
            let token = (try? JSONDecoder().decode(TokenPayload.self, from: Data(message.request.utf8)))?.requestToken
            if let pending, pending.tab === tab, pending.token == token {
                finish(pending, .failure(.abort("The operation was aborted.")))
            }
            tab.respondToPageMessage(requestId: message.requestId, success: true, response: "")
            return
        }
        guard #available(macOS 13.5, *), isAvailable, let suffixes, let origin = message.origin else {
            return reply(tab, message.requestId, fallback: true)
        }
        let data = Data(message.request.utf8)
        let isCreate = message.type == "webauthnCreate"
        let requests: [ASAuthorizationRequest]
        let token: String?
        let timeout: TimeInterval
        var wantsCredProps = false
        if isCreate {
            guard let request = try? JSONDecoder().decode(WebAuthnCreateRequest.self, from: data) else {
                return reject(tab, message.requestId, .type("The passkey options could not be read."))
            }
            token = request.requestToken
            switch WebAuthnPlanner.plan(request, origin: origin, suffixes: suffixes) {
            case .fallback: return reply(tab, message.requestId, fallback: true)
            case .failure(let error): return reject(tab, message.requestId, error)
            case .plan(let plan):
                requests = Self.registrationRequests(plan)
                timeout = plan.timeout
                wantsCredProps = plan.wantsCredProps
            }
        } else {
            guard let request = try? JSONDecoder().decode(WebAuthnGetRequest.self, from: data) else {
                return reject(tab, message.requestId, .type("The passkey options could not be read."))
            }
            token = request.requestToken
            switch WebAuthnPlanner.plan(request, origin: origin, suffixes: suffixes) {
            case .fallback: return reply(tab, message.requestId, fallback: true)
            case .failure(let error): return reject(tab, message.requestId, error)
            case .plan(let plan):
                requests = Self.assertionRequests(plan)
                timeout = plan.timeout
            }
        }
        guard !requests.isEmpty else {
            // A security-key-only request before macOS 14.4: Chromium's own
            // flow handles security keys.
            return reply(tab, message.requestId, fallback: true)
        }
        // The sheet covers the window, so only the tab the user is looking
        // at may raise it. An agent window is never key, so it never can.
        guard let window = tab.hostView.window, window.isKeyWindow, !tab.hostView.isHiddenOrHasHiddenAncestor else {
            return reject(tab, message.requestId, .notAllowed("Passkeys can only be used from the tab in the active window."))
        }
        guard pending == nil, !awaitingPermission else {
            return reject(tab, message.requestId, .notAllowed("A passkey request is already in progress."))
        }
        let requestId = message.requestId
        let start = { [weak self, weak tab] (permitted: Bool) in
            guard let self, let tab else { return }
            let allowed = permitted ? requests : requests.filter { !Self.isPlatformRequest($0) }
            guard !allowed.isEmpty else { return self.reply(tab, requestId, fallback: true) }
            self.perform(allowed, tab: tab, window: window, requestId: requestId, token: token,
                         timeout: timeout, isCreate: isCreate, wantsCredProps: wantsCredProps)
        }
        // macOS refuses every iCloud Keychain request, with no sheet, until
        // the user has let this app use their passkeys
        // (kTCCServiceWebBrowserPublicKeyCredential). WebKit tabs do not
        // need it, so a WebKit sign-in says nothing about this.
        let manager = ASAuthorizationWebBrowserPublicKeyCredentialManager()
        switch manager.authorizationStateForPlatformCredentials {
        case .authorized:
            start(true)
        case .denied:
            start(false)
        case .notDetermined:
            awaitingPermission = true
            manager.requestAuthorizationForPublicKeyCredentials { state in
                withExtendedLifetime(manager) {}
                DispatchQueue.main.async { [weak self] in
                    self?.awaitingPermission = false
                    start(state == .authorized)
                }
            }
        @unknown default:
            start(false)
        }
    }

    @available(macOS 13.5, *)
    private static func isPlatformRequest(_ request: ASAuthorizationRequest) -> Bool {
        request is ASAuthorizationPlatformPublicKeyCredentialAssertionRequest
            || request is ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest
    }

    @available(macOS 13.5, *)
    private func perform(_ requests: [ASAuthorizationRequest], tab: Tab, window: NSWindow, requestId: Int64, token: String?,
                         timeout: TimeInterval, isCreate: Bool, wantsCredProps: Bool) {
        let controller = ASAuthorizationController(authorizationRequests: requests)
        let entry = Pending(token: token, requestId: requestId, tab: tab, window: window,
                            controller: controller, isCreate: isCreate, wantsCredProps: wantsCredProps)
        pending = entry
        controller.delegate = self
        controller.presentationContextProvider = self
        entry.timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self, weak entry] _ in
            guard let self, let entry else { return }
            self.finish(entry, .failure(.notAllowed("The operation either timed out or was not allowed.")))
        }
        controller.performRequests()
    }

    // MARK: Requests

    @available(macOS 13.5, *)
    private static func assertionRequests(_ plan: WebAuthnAssertionPlan) -> [ASAuthorizationRequest] {
        var clientData = ASPublicKeyCredentialClientData(challenge: plan.challenge, origin: plan.origin)
        clientData.crossOrigin = .sameOriginWithAncestors
        let uv = userVerification(plan.userVerification)

        let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: plan.rpId)
            .createCredentialAssertionRequest(clientData: clientData)
        platform.allowedCredentials = plan.allowCredentials.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
        platform.userVerificationPreference = uv
        platform.shouldShowHybridTransport = true
        var requests: [ASAuthorizationRequest] = [platform]

        if #available(macOS 14.4, *) {
            let securityKey = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: plan.rpId)
                .createCredentialAssertionRequest(clientData: clientData)
            securityKey.allowedCredentials = zip(plan.allowCredentials, plan.allowTransports).map { id, transports in
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: id, transports: Self.transports(transports))
            }
            securityKey.userVerificationPreference = uv
            requests.append(securityKey)
        }
        return requests
    }

    @available(macOS 13.5, *)
    private static func registrationRequests(_ plan: WebAuthnRegistrationPlan) -> [ASAuthorizationRequest] {
        var clientData = ASPublicKeyCredentialClientData(challenge: plan.challenge, origin: plan.origin)
        clientData.crossOrigin = .sameOriginWithAncestors
        let uv = userVerification(plan.userVerification)
        var requests: [ASAuthorizationRequest] = []

        if plan.offerPlatform {
            let platform = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: plan.rpId)
                .createCredentialRegistrationRequest(clientData: clientData, name: plan.userName, userID: plan.userID)
            platform.displayName = plan.userDisplayName
            platform.userVerificationPreference = uv
            platform.excludedCredentials = plan.excludeCredentials.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
            platform.shouldShowHybridTransport = true
            requests.append(platform)
        }
        if plan.offerSecurityKey, #available(macOS 14.4, *) {
            let securityKey = ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: plan.rpId)
                .createCredentialRegistrationRequest(clientData: clientData, displayName: plan.userDisplayName,
                                                     name: plan.userName, userID: plan.userID)
            securityKey.credentialParameters = plan.algorithms.map {
                ASAuthorizationPublicKeyCredentialParameters(algorithm: ASCOSEAlgorithmIdentifier(rawValue: $0))
            }
            securityKey.excludedCredentials = plan.excludeCredentials.map {
                ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor(credentialID: $0, transports: ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported)
            }
            securityKey.residentKeyPreference = residentKey(plan.residentKey)
            securityKey.userVerificationPreference = uv
            securityKey.attestationPreference = attestation(plan.attestation)
            requests.append(securityKey)
        }
        return requests
    }

    private static func userVerification(_ value: String) -> ASAuthorizationPublicKeyCredentialUserVerificationPreference {
        switch value {
        case "required": return .required
        case "discouraged": return .discouraged
        default: return .preferred
        }
    }

    private static func residentKey(_ value: String) -> ASAuthorizationPublicKeyCredentialResidentKeyPreference {
        switch value {
        case "required": return .required
        case "preferred": return .preferred
        default: return .discouraged
        }
    }

    private static func attestation(_ value: String) -> ASAuthorizationPublicKeyCredentialAttestationKind {
        switch value {
        case "direct": return .direct
        case "indirect": return .indirect
        case "enterprise": return .enterprise
        default: return .none
        }
    }

    private static func transports(_ names: [String]) -> [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport] {
        let mapped = names.compactMap { name -> ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport? in
            switch name {
            case "usb": return .usb
            case "nfc": return .nfc
            case "ble": return .bluetooth
            default: return nil
            }
        }
        return mapped.isEmpty ? ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport.allSupported : mapped
    }

    private static func transportNames(_ transports: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport]) -> [String] {
        transports.compactMap {
            switch $0 {
            case .usb: return "usb"
            case .nfc: return "nfc"
            case .bluetooth: return "ble"
            default: return nil
            }
        }
    }

    // MARK: Results

    private func finish(_ entry: Pending, _ result: Result<[String: Any], WebAuthnError>) {
        guard pending === entry else { return }
        pending = nil
        entry.timer?.invalidate()
        if case .failure = result, #available(macOS 13.0, *) {
            entry.controller.cancel()
        }
        guard let tab = entry.tab else { return }
        switch result {
        case .success(let credential):
            let json = (try? JSONSerialization.data(withJSONObject: credential)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            tab.respondToPageMessage(requestId: entry.requestId, success: true, response: json)
        case .failure(let error):
            reject(tab, entry.requestId, error)
        }
    }

    private func reply(_ tab: Tab, _ requestId: Int64, fallback: Bool) {
        tab.respondToPageMessage(requestId: requestId, success: true, response: fallback ? #"{"fallback":true}"# : "{}")
    }

    private func reject(_ tab: Tab, _ requestId: Int64, _ error: WebAuthnError) {
        let body = (try? JSONSerialization.data(withJSONObject: ["name": error.name, "message": error.message]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        tab.respondToPageMessage(requestId: requestId, success: false, response: body)
    }

    @available(macOS 13.5, *)
    private func credentialJSON(_ credential: ASAuthorization, for entry: Pending) -> [String: Any]? {
        switch credential.credential {
        case let assertion as ASAuthorizationPlatformPublicKeyCredentialAssertion:
            return assertionJSON(assertion, attachment: assertion.attachment == .platform ? "platform" : "cross-platform")
        case let assertion as ASAuthorizationSecurityKeyPublicKeyCredentialAssertion:
            return assertionJSON(assertion, attachment: "cross-platform")
        case let registration as ASAuthorizationPlatformPublicKeyCredentialRegistration:
            let isPlatform = registration.attachment == .platform
            return registrationJSON(registration, attachment: isPlatform ? "platform" : "cross-platform",
                                    transports: isPlatform ? ["hybrid", "internal"] : ["hybrid"],
                                    discoverable: true, wantsCredProps: entry.wantsCredProps)
        case let registration as ASAuthorizationSecurityKeyPublicKeyCredentialRegistration:
            var transports: [String] = []
            if #available(macOS 14.5, *) { transports = Self.transportNames(registration.transports) }
            return registrationJSON(registration, attachment: "cross-platform", transports: transports,
                                    discoverable: nil, wantsCredProps: entry.wantsCredProps)
        default:
            return nil
        }
    }

    private func assertionJSON(_ assertion: ASAuthorizationPublicKeyCredentialAssertion, attachment: String) -> [String: Any] {
        var response: [String: Any] = [
            "clientDataJSON": Base64URL.encode(assertion.rawClientDataJSON),
            "authenticatorData": Base64URL.encode(assertion.rawAuthenticatorData),
            "signature": Base64URL.encode(assertion.signature),
        ]
        if !assertion.userID.isEmpty {
            response["userHandle"] = Base64URL.encode(assertion.userID)
        }
        return [
            "id": Base64URL.encode(assertion.credentialID),
            "authenticatorAttachment": attachment,
            "response": response,
            "clientExtensionResults": [String: Any](),
        ]
    }

    /// `discoverable` is what credProps reports as `rk`: always true for an
    /// iCloud Keychain passkey, unknown for a security key.
    private func registrationJSON(_ registration: ASAuthorizationPublicKeyCredentialRegistration, attachment: String,
                                  transports: [String], discoverable: Bool?, wantsCredProps: Bool) -> [String: Any]? {
        guard let attestationObject = registration.rawAttestationObject,
              let parsed = WebAuthnAttestation(attestationObject: attestationObject)
        else { return nil }
        var response: [String: Any] = [
            "clientDataJSON": Base64URL.encode(registration.rawClientDataJSON),
            "attestationObject": Base64URL.encode(attestationObject),
            "authenticatorData": Base64URL.encode(parsed.authenticatorData),
            "publicKeyAlgorithm": parsed.publicKeyAlgorithm,
            "transports": transports,
        ]
        if let key = parsed.publicKey {
            response["publicKey"] = Base64URL.encode(key)
        }
        var extensions: [String: Any] = [:]
        if wantsCredProps {
            extensions["credProps"] = discoverable.map { ["rk": $0] } ?? [String: Any]()
        }
        return [
            "id": Base64URL.encode(registration.credentialID),
            "authenticatorAttachment": attachment,
            "response": response,
            "clientExtensionResults": extensions,
        ]
    }

    // MARK: Availability

    private static func loadSuffixList() -> PublicSuffixList? {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat", subdirectory: "Passkeys"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            NSLog("Browser: the Public Suffix List is missing, so CEF tabs keep Chromium's own passkey flow")
            return nil
        }
        let list = PublicSuffixList(datText: text)
        return list.isEmpty ? nil : list
    }

    /// Only a build signed with Apple's grant and its provisioning profile
    /// carries the key (see the Passkeys note in AGENTS.md). Without it the
    /// system refuses every request that names an origin.
    private static let hasBrowserPasskeyEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil)
        else { return false }
        return (value as? Bool) == true
    }()
}

extension PlatformPasskeyBroker: ASAuthorizationControllerDelegate {
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let entry = pending, entry.controller === controller else { return }
        guard #available(macOS 13.5, *), let json = credentialJSON(authorization, for: entry) else {
            return finish(entry, .failure(.notAllowed("The passkey response could not be read.")))
        }
        finish(entry, .success(json))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard let entry = pending, entry.controller === controller else { return }
        let code = (error as NSError).domain == ASAuthorizationError.errorDomain ? (error as NSError).code : 0
        // 1006 is ASAuthorizationError.matchedExcludedCredential (macOS 15+):
        // the authenticator already holds one of excludeCredentials.
        if code == 1006 {
            return finish(entry, .failure(.invalidState("The authenticator already holds a credential for this account.")))
        }
        finish(entry, .failure(.notAllowed("The operation either timed out or was not allowed.")))
    }
}

extension PlatformPasskeyBroker: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        pending?.window ?? NSApp.keyWindow ?? NSWindow()
    }
}
