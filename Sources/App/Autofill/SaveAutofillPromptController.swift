import AppKit

private final class SaveAutofillPromptViewController: NSViewController {
    private static let contentSize = NSSize(width: 300, height: 92)

    private let messageText: String
    private let onSave: () -> Void
    private let onNotNow: () -> Void

    init(message: String, onSave: @escaping () -> Void, onNotNow: @escaping () -> Void) {
        self.messageText = message
        self.onSave = onSave
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
        saveButton.frame = NSRect(x: size.width - margin - 80, y: margin, width: 80, height: buttonHeight)
        container.addSubview(saveButton)

        let notNowButton = NSButton(title: "Not Now", target: self, action: #selector(notNowTapped))
        notNowButton.bezelStyle = .rounded
        notNowButton.frame = NSRect(x: size.width - margin - 80 - 8 - 90, y: margin, width: 90, height: buttonHeight)
        container.addSubview(notNowButton)

        view = container
    }

    @objc private func saveTapped() { onSave() }
    @objc private func notNowTapped() { onNotNow() }
}

/// "Save this card ending 4242?" / "Save this address?" popover
/// (browser-ojh.2) -- Save/Not Now only, no persisted "Never" opt-out the
/// way SavePasswordPromptController has (a security-relevant credential
/// warrants that extra control; a card or address is lower-stakes and
/// simply not saving it this time, every time, is an acceptable v1
/// scope). Same NSPopover-anchored pattern as SavePasswordPromptController/
/// PermissionPromptController, reused for one instance per window handling
/// both cards and addresses (never more than one prompt showing at a
/// time, same as those).
final class SaveAutofillPromptController: NSObject, NSPopoverDelegate {
    /// A fresh popover per prompt -- see SavePasswordPromptController for
    /// why a reused one cleared the next prompt's state.
    private var popover: NSPopover?
    private var isPending = false

    var isShowing: Bool { popover?.isShown ?? false }

    func show(message: String, anchorView: NSView, onSave: @escaping () -> Void) {
        dismiss()
        isPending = true

        let content = SaveAutofillPromptViewController(
            message: message,
            onSave: { [weak self] in self?.complete { onSave() } },
            onNotNow: { [weak self] in self?.complete {} }
        )
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.delegate = self
        popover.contentViewController = content
        popover.contentSize = content.preferredContentSize
        self.popover = popover
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    func dismiss() {
        isPending = false
        let closing = popover
        popover = nil
        if let closing, closing.isShown {
            closing.performClose(nil)
        }
    }

    private func complete(_ action: () -> Void) {
        guard isPending else { return }
        isPending = false
        popover?.performClose(nil)
        action()
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        isPending = false
        popover = nil
    }
}
