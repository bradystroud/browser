import AppKit

/// Handles the kAEGetURL Apple Event that macOS sends when this app is asked
/// to open a URL -- as the system default browser, or via `open -a Browser
/// <url>` -- whether that cold-launches the app or it's already running.
/// Registered from applicationWillFinishLaunching, not the older
/// application(_:open:) delegate method, per Finicky's main.m (see
/// docs/research/2026-07-27-link-routing-macos.md section 2).
final class URLEventHandler: NSObject {
    static let shared = URLEventHandler()

    private override init() {
        super.init()
    }

    func register() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            return
        }

        // keySenderPIDAttr, not keyAddressAttr/typeApplicationBundleID -- see
        // docs/research/2026-07-27-link-routing-macos.md section 3. Resolves
        // to nil if the sender has already exited, or if an intermediary
        // (the `open` CLI, a shell script, another router) is the actual
        // Apple Event sender rather than the original app -- both cases are
        // indistinguishable from "no source" here and treated the same by
        // RoutingCoordinator (falls back to the default profile).
        var sourceBundleId: String?
        if let senderPIDDescriptor = event.attributeDescriptor(forKeyword: keySenderPIDAttr) {
            let pid = senderPIDDescriptor.int32Value
            sourceBundleId = SourceAppResolver.resolve(senderPID: pid_t(pid))?.bundleIdentifier
        }

        RoutingCoordinator.shared.route(url: urlString, sourceBundleId: sourceBundleId)
    }
}
