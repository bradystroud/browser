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
    /// Set exactly when `openIn` is `.otherApp`.
    public let appBundleId: String?

    public init(openIn: RoutingRule.OpenIn, reason: Reason, appBundleId: String? = nil) {
        self.openIn = openIn
        self.reason = reason
        self.appBundleId = appBundleId
    }

    /// A rule's explicit choice wins in both directions -- so one site can
    /// always get a little window while the preference is off, or always get
    /// a real tab while it is on. Only when the rule is silent, or no rule
    /// matched, does the preference apply. A rule set to `.otherApp` with no
    /// app named counts as silent.
    public static func resolve(
        evaluation: RuleEvaluation,
        preferLittleWindowForExternalLinks: Bool
    ) -> LinkOpening {
        if case .matched(let rule, _) = evaluation, let appBundleId = rule.action.otherAppBundleId {
            return LinkOpening(openIn: .otherApp, reason: .rule, appBundleId: appBundleId)
        }
        if let openIn = evaluation.openIn, openIn != .otherApp {
            return LinkOpening(openIn: openIn, reason: .rule)
        }
        return preferLittleWindowForExternalLinks
            ? LinkOpening(openIn: .littleWindow, reason: .preference)
            : LinkOpening(openIn: .browser, reason: .default)
    }
}
