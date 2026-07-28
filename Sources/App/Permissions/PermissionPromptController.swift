import AppKit

private final class PermissionPromptViewController: NSViewController {
    private static let contentSize = NSSize(width: 300, height: 92)

    private let messageText: String
    private let onAllow: () -> Void
    private let onDontAllow: () -> Void

    init(message: String, onAllow: @escaping () -> Void, onDontAllow: @escaping () -> Void) {
        self.messageText = message
        self.onAllow = onAllow
        self.onDontAllow = onDontAllow
        super.init(nibName: nil, bundle: nil)
        // NSViewController already declares preferredContentSize (settable,
        // used by NSPopover to size itself) -- just set it, don't redeclare it.
        preferredContentSize = Self.contentSize
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let size = Self.contentSize
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let margin: CGFloat = 14

        let label = NSTextField(wrappingLabelWithString: messageText)
        label.font = .systemFont(ofSize: 13)
        label.frame = NSRect(x: margin, y: 40, width: size.width - margin * 2, height: 42)
        container.addSubview(label)

        let buttonHeight: CGFloat = 24
        let allowButton = NSButton(title: "Allow", target: self, action: #selector(allowTapped))
        allowButton.bezelStyle = .rounded
        allowButton.keyEquivalent = "\r"
        allowButton.frame = NSRect(x: size.width - margin - 80, y: margin, width: 80, height: buttonHeight)
        container.addSubview(allowButton)

        let dontAllowButton = NSButton(title: "Don't Allow", target: self, action: #selector(dontAllowTapped))
        dontAllowButton.bezelStyle = .rounded
        dontAllowButton.frame = NSRect(x: size.width - margin - 80 - 8 - 100, y: margin, width: 100, height: buttonHeight)
        container.addSubview(dontAllowButton)

        view = container
    }

    @objc private func allowTapped() { onAllow() }
    @objc private func dontAllowTapped() { onDontAllow() }
}

/// Safari-style permission prompt -- "example.com wants to use your camera
/// and microphone" with Allow/Don't Allow -- shown as an NSPopover anchored
/// under the omnibox, matching where Safari/Chrome anchor this exact kind of
/// prompt. One instance per BrowserWindowController; at most one request
/// showing at a time.
final class PermissionPromptController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var pendingDecision: ((Bool) -> Void)?

    override init() {
        super.init()
        // Closes on an outside click like a real popover (unlike
        // .applicationDefined, which would require us to close it
        // ourselves) -- popoverDidClose below treats that as "Don't Allow"
        // rather than leaving the underlying request unanswered forever.
        popover.behavior = .semitransient
        popover.delegate = self
    }

    var isShowing: Bool { popover.isShown }

    func show(kinds: EnginePermissionKind, origin: String, anchorView: NSView, decision: @escaping (Bool) -> Void) {
        // At most one prompt at a time -- deny whatever was pending before
        // showing the new one, same as any other app-initiated dismissal.
        dismiss(invokingDecision: true)
        pendingDecision = decision

        let content = PermissionPromptViewController(
            message: Self.message(kinds: kinds, origin: origin),
            onAllow: { [weak self] in self?.complete(allow: true) },
            onDontAllow: { [weak self] in self?.complete(allow: false) }
        )
        popover.contentViewController = content
        popover.contentSize = content.preferredContentSize
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    /// Tears down the popover. `invokingDecision` controls whether the
    /// pending request's `decision` block is called with `false` (deny) as
    /// part of tearing it down:
    /// - `true` for app-initiated dismissal (tab switch, window close,
    ///   denying a stale prompt before showing a new one) -- we're allowed
    ///   to answer the underlying request ourselves in these cases.
    /// - `false` when CEF itself says the request is already moot (see
    ///   BRWBrowser.h's -browserDidDismissPermissionRequest:) -- its own
    ///   underlying callback may no longer be valid to invoke by then, so
    ///   this only tears down the UI, never calls `decision`.
    func dismiss(invokingDecision: Bool) {
        let decision = pendingDecision
        pendingDecision = nil
        if popover.isShown {
            popover.performClose(nil)
        }
        if invokingDecision {
            decision?(false)
        }
    }

    private func complete(allow: Bool) {
        guard let decision = pendingDecision else { return }
        pendingDecision = nil
        popover.performClose(nil)
        decision(allow)
    }

    private static func message(kinds: EnginePermissionKind, origin: String) -> String {
        let host = URL(string: origin)?.host ?? origin
        if kinds == [.notifications] {
            return "\(host) wants to send you notifications"
        }
        var parts: [String] = []
        if kinds.contains(.camera) { parts.append("camera") }
        if kinds.contains(.microphone) { parts.append("microphone") }
        if kinds.contains(.geolocation) { parts.append("location") }
        if kinds.contains(.notifications) { parts.append("send notifications") }
        return "\(host) wants to use your \(parts.joined(separator: " and "))"
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Fires for every close, including ones this controller triggered
        // itself via performClose(nil) in dismiss(invokingDecision:)/
        // complete(allow:) -- both already nil pendingDecision first, so
        // this is a no-op in those cases and only actually denies on an
        // outside click / Esc the user triggered directly.
        guard let decision = pendingDecision else { return }
        pendingDecision = nil
        decision(false)
    }
}
