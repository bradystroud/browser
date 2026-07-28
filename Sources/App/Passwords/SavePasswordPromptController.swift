import AppKit

private final class SavePasswordPromptViewController: NSViewController {
    private static let contentSize = NSSize(width: 340, height: 92)

    private let messageText: String
    private let onSave: () -> Void
    private let onNever: () -> Void
    private let onNotNow: () -> Void

    init(message: String, onSave: @escaping () -> Void, onNever: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.messageText = message
        self.onSave = onSave
        self.onNever = onNever
        self.onNotNow = onNotNow
        super.init(nibName: nil, bundle: nil)
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
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveTapped))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: size.width - margin - 70, y: margin, width: 70, height: buttonHeight)
        container.addSubview(saveButton)

        let notNowButton = NSButton(title: "Not Now", target: self, action: #selector(notNowTapped))
        notNowButton.bezelStyle = .rounded
        notNowButton.frame = NSRect(x: size.width - margin - 70 - 8 - 80, y: margin, width: 80, height: buttonHeight)
        container.addSubview(notNowButton)

        let neverButton = NSButton(title: "Never", target: self, action: #selector(neverTapped))
        neverButton.bezelStyle = .rounded
        neverButton.frame = NSRect(x: margin, y: margin, width: 70, height: buttonHeight)
        container.addSubview(neverButton)

        view = container
    }

    @objc private func saveTapped() { onSave() }
    @objc private func neverTapped() { onNever() }
    @objc private func notNowTapped() { onNotNow() }
}

/// "Save password for example.com?" popover -- Save / Never / Not Now,
/// same NSPopover-anchored-under-the-omnibox pattern as
/// PermissionPromptController (browser-12m.2), reused rather than
/// duplicated-from-scratch: this app's Alloy-style windows have no chrome
/// UI of their own to surface Chromium's native save-password bar, so every
/// prompt like this is one of ours. One instance per window (see
/// PasswordManagerController, which owns this), at most one prompt showing
/// at a time.
///
/// "Not Now" and dismissing without an answer (outside click, Esc, tab
/// switch) are the same outcome -- do nothing, ask again next submit -- so
/// there's no separate onDismiss distinction to make here the way
/// PermissionPromptController needs one (a permission request has an
/// underlying CEF callback that must be answered one way or another; a
/// save-password prompt has no such callback -- the page's form already
/// submitted successfully by the time this shows, nothing is pending on
/// CEF's side waiting for this decision).
final class SavePasswordPromptController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private var isPending = false

    override init() {
        super.init()
        popover.behavior = .semitransient
        popover.delegate = self
    }

    var isShowing: Bool { popover.isShown }

    func show(origin: String, anchorView: NSView, onSave: @escaping () -> Void, onNever: @escaping () -> Void) {
        dismiss()
        isPending = true

        let host = URL(string: origin)?.host ?? origin
        let content = SavePasswordPromptViewController(
            message: "Save password for \(host)?",
            onSave: { [weak self] in self?.complete { onSave() } },
            onNever: { [weak self] in self?.complete { onNever() } },
            onNotNow: { [weak self] in self?.complete {} }
        )
        popover.contentViewController = content
        popover.contentSize = content.preferredContentSize
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    /// Tears down the popover without invoking either callback -- used when
    /// something else needs the prompt gone (a new one about to show, the
    /// tab switching away) rather than the user actually answering it.
    func dismiss() {
        isPending = false
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func complete(_ action: () -> Void) {
        guard isPending else { return }
        isPending = false
        popover.performClose(nil)
        action()
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // An outside click / Esc closes the popover without going through
        // complete(_:) -- treat that exactly like "Not Now" (do nothing).
        isPending = false
    }
}
