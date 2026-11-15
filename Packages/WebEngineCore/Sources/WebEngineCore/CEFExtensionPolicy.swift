import Foundation

/// Whether an extension may run in CEF tabs, and what Chromium would grant
/// it if it did.
///
/// Chromium loads a `--load-extension` folder as an unpacked extension and
/// grants it every permission and host pattern its manifest names, at load,
/// with no prompt. So the user's consent has to be asked for before the
/// folder goes on the switch, and the text for it comes from here.
public enum CEFExtensionPolicy {
    public enum Refusal: Equatable, Sendable {
        case unreadableManifest
        /// Only Manifest V3 runs: a V2 background page is outside what the
        /// shim wraps. `found` is nil when the manifest names no version.
        case notManifestV3(found: Int?)
        /// The manifest has a `manifest_version` that is not a whole number.
        case invalidManifestVersion
        /// `debugger.attach` works on any app tab with no prompt and no sign
        /// on screen, so an extension that can ask for it never runs here.
        case debuggerPermission
        /// A permission whose API acts on the whole Chromium profile in ways
        /// the app cannot see or undo (see `refusedPermissions`).
        case unsupportedPermission(String)

        /// A sentence the UI can show next to the extension.
        public var message: String {
            switch self {
            case .unreadableManifest:
                return "The extension's manifest.json could not be read."
            case .notManifestV3(let found):
                if let found { return "It uses Manifest V\(found). Only Manifest V3 extensions run in Chromium tabs." }
                return "Its manifest names no version. Only Manifest V3 extensions run in Chromium tabs."
            case .invalidManifestVersion:
                return "Its manifest names an invalid manifest version. Only Manifest V3 extensions run in Chromium tabs."
            case .debuggerPermission:
                return "It asks for the debugger permission, which would let it read and control every page in the browser."
            case .unsupportedPermission(let name):
                return CEFExtensionPolicy.refusedPermissions[name] ?? "It asks for the \(name) permission, which Chromium tabs do not support."
            }
        }
    }

    public struct Verdict: Equatable, Sendable {
        public let refusal: Refusal?
        /// API permissions Chromium grants at load, in manifest order.
        public let permissions: [String]
        /// Host match patterns Chromium grants at load: `host_permissions`
        /// and the `matches` of every content script.
        public let hostPatterns: [String]
        /// Permissions and host patterns the extension may request later.
        /// Not granted at load.
        public let optionalPermissions: [String]
        public let optionalHostPatterns: [String]

        /// Extra consent wording for permissions that act on the profile's
        /// Chromium tabs as a whole, keyed by permission name.
        public var consentNotes: [String: String] {
            var notes: [String: String] = [:]
            for name in permissions + optionalPermissions { if let note = CEFExtensionPolicy.consentNotes[name] { notes[name] = note } }
            return notes
        }

        public var canRun: Bool { refusal == nil }
        public var reason: String? { refusal?.message }

        /// The granted set in the form `InstalledWebExtension.grants` stores.
        public var grants: [String] {
            WebExtensionGrants.make(permissions: permissions, matchPatterns: hostPatterns)
        }
    }

    /// Refused for Chromium tabs, required or optional. Chromium's own
    /// implementation of each acts on the profile with no prompt and no view
    /// in the app, or changes what the app believes about the extensions.
    public static let refusedPermissions: [String: String] = [
        "management": "It asks for the management permission, which would let it disable or remove other extensions of the profile.",
        "contentSettings": "It asks for the contentSettings permission, which would let it grant site permissions such as camera and location before the app asks the user.",
        "browsingData": "It asks for the browsingData permission, which would let it clear the cookies and site data of the profile's Chromium tabs.",
        "webAuthenticationProxy": "It asks for the webAuthenticationProxy permission, which would let it intercept sign-in with passkeys in Chromium tabs.",
    ]

    /// Permissions that run but change the Chromium tabs of the whole profile.
    public static let consentNotes: [String: String] = [
        "proxy": "Control the network proxy of all Chromium tabs in this profile",
        "privacy": "Change privacy settings that apply to all Chromium tabs in this profile",
    ]

    public static func evaluate(manifestData: Data) -> Verdict {
        guard let manifest = try? parseManifest(manifestData) else { return unreadable }
        return evaluate(manifest: manifest)
    }

    public static func evaluate(manifest: [String: Any]) -> Verdict {
        let permissions = names(manifest["permissions"]).filter { !isMatchPattern($0) }
        let optionalPermissions = names(manifest["optional_permissions"]).filter { !isMatchPattern($0) }

        var hosts = webPatterns(names(manifest["host_permissions"]))
        for script in manifest["content_scripts"] as? [Any] ?? [] {
            hosts += webPatterns(names((script as? [String: Any])?["matches"]))
        }
        let optionalHosts = webPatterns(names(manifest["optional_host_permissions"]))

        let refusal: Refusal?
        var version: Int?
        let named = manifest["manifest_version"] != nil
        if let number = manifest["manifest_version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.doubleValue == number.doubleValue.rounded() {
            version = Int(exactly: number.doubleValue)
        }
        let asked = permissions + optionalPermissions
        if version == nil && named {
            refusal = .invalidManifestVersion
        } else if version != 3 {
            refusal = .notManifestV3(found: version)
        } else if asked.contains("debugger") {
            refusal = .debuggerPermission
        } else if let name = asked.first(where: { refusedPermissions[$0] != nil }) {
            refusal = .unsupportedPermission(name)
        } else {
            refusal = nil
        }
        return Verdict(
            refusal: refusal,
            permissions: permissions,
            hostPatterns: unique(hosts.filter { $0 != CEFExtensionShim.bridgeHostPermission }),
            optionalPermissions: optionalPermissions,
            optionalHostPatterns: optionalHosts
        )
    }

    /// Match patterns as the prepared manifest holds them. Chromium gives a
    /// command-line extension access to `file:` URLs with no switch to turn
    /// it off (a store install has it off), so nothing a prepared copy asks for
    /// may cover `file:`. By Chrome's match-pattern rules `<all_urls>` includes
    /// the `file` scheme and `*://` does not (it is http and https), so
    /// `<all_urls>` becomes the two web patterns, and a pattern whose scheme is
    /// `file` is dropped. Repeats are removed.
    public static func webPatterns(_ patterns: [String]) -> [String] {
        var out: [String] = []
        for pattern in patterns {
            if pattern == "<all_urls>" {
                out += ["http://*/*", "https://*/*"]
            } else if let range = pattern.range(of: "://"), pattern[..<range.lowerBound].lowercased() == "file" {
                continue
            } else {
                out.append(pattern)
            }
        }
        return unique(out)
    }

    // MARK: - Pieces

    static let unreadable = Verdict(
        refusal: .unreadableManifest, permissions: [], hostPatterns: [], optionalPermissions: [], optionalHostPatterns: []
    )

    /// A manifest in Chrome's reading of JSON: a byte-order mark and the
    /// comments Chrome tolerates are accepted.
    static func parseManifest(_ data: Data) throws -> [String: Any] {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let manifest = try JSONSerialization.jsonObject(with: bytes, options: [.json5Allowed]) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    /// The strings of an array, in order, without repeats.
    static func names(_ value: Any?) -> [String] {
        unique((value as? [Any] ?? []).compactMap { $0 as? String })
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// Manifest V3 allows match patterns only in the host lists; one written
    /// into `permissions` is not a permission there and Chromium ignores it.
    static func isMatchPattern(_ name: String) -> Bool {
        name == "<all_urls>" || name.contains("://")
    }
}
