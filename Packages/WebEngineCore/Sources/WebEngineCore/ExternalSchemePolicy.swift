import Foundation

/// What to do when a page navigates to a URL that belongs to another app
/// (zoommtg:, facetime:, smb:, slack:, mailto:, ...).
///
/// Handing a URL to another app leaves the browser's sandbox of origins
/// entirely: a file-server scheme mounts a share, a calling scheme starts a
/// call. So no page may do it on its own. Only a mail or phone link the user
/// has just clicked opens straight away, because that is exactly what the
/// click says; every other external URL is put to the user first, and a
/// subframe the user never touched (an ad iframe redirecting itself) is not
/// even allowed to ask.
public enum ExternalSchemePolicy {
    public enum Decision: Equatable, Sendable {
        case openDirectly
        case askFirst
        case ignore
    }

    /// Schemes whose only effect is to start writing a message or dialling,
    /// both of which the user still has to complete in the other app.
    public static let directOnClickSchemes: Set<String> = ["mailto", "tel"]

    /// `userClicked` must come from the engine's own account of a user
    /// gesture on a link, never from anything the page reports.
    public static func decide(scheme: String, userClicked: Bool, isMainFrame: Bool) -> Decision {
        if userClicked, directOnClickSchemes.contains(scheme.lowercased()) {
            return .openDirectly
        }
        if userClicked || isMainFrame {
            return .askFirst
        }
        return .ignore
    }
}
