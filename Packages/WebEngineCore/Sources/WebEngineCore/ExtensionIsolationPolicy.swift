import Foundation

/// Which pages a profile's browser extensions may reach, and the one way to
/// let agent-driven pages (`browser page`) reach them.
///
/// An agent page runs in a signed-in profile, so a password-manager
/// extension in that profile would offer the user's saved accounts to
/// whatever drives the page, and the agent could open the extension's own
/// pages and talk to its background. So agent pages and the profile's
/// extensions never meet: the tab is built without the extension system,
/// extension URLs are refused, and extensions are never told the window
/// exists. The only exception is a test instance launched with both
/// `--allow-agent-extensions` and a `--profiles-root` that is not the real
/// one, so an agent can still exercise an extension it installed there.
public enum ExtensionIsolationPolicy {
    public static let allowAgentExtensionsFlag = "--allow-agent-extensions"

    /// The schemes extension pages are served from: Chrome's, which the
    /// WebKit adapter uses as its own, and the ones WebKit and other engines
    /// use by default.
    public static let extensionSchemes: Set<String> = [
        "chrome-extension", "safari-web-extension", "webkit-extension", "moz-extension", "extension",
    ]

    public static func isExtensionURL(_ url: String) -> Bool {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        return extensionSchemes.contains(trimmed[..<colon].lowercased())
    }

    /// Whether this launch lets agent pages run the profile's extensions.
    ///
    /// - Parameters:
    ///   - arguments: the app's own command line. The CLI cannot add to it.
    ///   - profilesRootOverride: the canonical `--profiles-root`, or nil
    ///     when the launch has none.
    ///   - realDataDirectories: where a normal launch keeps its profiles
    ///     and metadata. An override equal to, inside or around any of
    ///     them is the real data, not a test instance.
    public static func agentPagesMayRunExtensions(
        arguments: [String], profilesRootOverride: String?, realDataDirectories: [String]
    ) -> Bool {
        guard arguments.contains(allowAgentExtensionsFlag), let override = profilesRootOverride,
              !override.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let root = normalized(override)
        return !realDataDirectories.map(normalized).contains { real in
            root == real || isInside(root, real) || isInside(real, root)
        }
    }

    private static func normalized(_ path: String) -> String {
        var standard = (path as NSString).standardizingPath
        while standard.count > 1, standard.hasSuffix("/") { standard.removeLast() }
        return standard
    }

    private static func isInside(_ path: String, _ directory: String) -> Bool {
        directory == "/" ? path != "/" : path.hasPrefix(directory + "/")
    }
}
