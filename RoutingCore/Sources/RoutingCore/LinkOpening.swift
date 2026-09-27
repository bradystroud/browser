import Foundation

/// Where a link that arrived from another app opens, and what decided it.
/// Shared by the app's RoutingCoordinator and `browser route-test`, so the
/// two can never disagree about whether a link gets a little window.
public struct LinkOpening: Equatable {
    public enum Reason: String, Codable, Equatable {
        /// The matched rule's own `openIn`.
        case rule
        /// No rule said, and the global little-window preference is on.
        case preference
        /// No rule said, and the preference is off.
        case `default`
    }

    public let openIn: RoutingRule.OpenIn
    public let reason: Reason

    public init(openIn: RoutingRule.OpenIn, reason: Reason) {
        self.openIn = openIn
        self.reason = reason
    }

    /// A rule's explicit choice wins in both directions -- so one site can
    /// always get a little window while the preference is off, or always get
    /// a real tab while it is on. Only when the rule is silent, or no rule
    /// matched, does the preference apply.
    public static func resolve(
        evaluation: RuleEvaluation,
        preferLittleWindowForExternalLinks: Bool
    ) -> LinkOpening {
        if let openIn = evaluation.openIn {
            return LinkOpening(openIn: openIn, reason: .rule)
        }
        return preferLittleWindowForExternalLinks
            ? LinkOpening(openIn: .littleWindow, reason: .preference)
            : LinkOpening(openIn: .browser, reason: .default)
    }
}
