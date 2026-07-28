import Foundation

/// Per-profile threat-warning configuration (browser-12m.6) -- deliberately
/// its own tiny persisted type rather than a field bolted onto
/// `BlockingSettings`: ad/tracker blocking and the phishing/malware warning
/// are two independent list categories with independent treatment (a
/// silent cancel vs. an interstitial the user can click through), so they
/// get independent settings too, even though both live in the same Privacy
/// pane UI. See `ThreatList`'s doc comment (BlockList reused as-is, a
/// second standalone instance) for why no new list type was needed
/// alongside this.
public struct ThreatWarningSettings: Codable, Equatable {
    public var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}
