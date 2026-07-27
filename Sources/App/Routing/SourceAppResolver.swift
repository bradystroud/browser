import AppKit

/// Resolves the sending app's identity from an Apple Event's sender PID, per
/// docs/research/2026-07-27-link-routing-macos.md section 3 (Finicky's
/// approach): keySenderPIDAttr -> NSRunningApplication, not
/// keyAddressAttr/typeApplicationBundleID. The PID can resolve to nil (sender
/// already exited, or an intermediary like `open` attributed the event to
/// itself instead of the original app) -- both cases are treated the same
/// way by callers as "no source", falling back to the default profile rather
/// than crashing or guessing.
enum SourceAppResolver {
    struct ResolvedSource {
        let bundleIdentifier: String?
        let localizedName: String?
    }

    static func resolve(senderPID: pid_t) -> ResolvedSource? {
        guard let app = NSRunningApplication(processIdentifier: senderPID) else { return nil }
        return ResolvedSource(bundleIdentifier: app.bundleIdentifier, localizedName: app.localizedName)
    }
}
