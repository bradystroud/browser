import AppKit

/// A brief confirmation ("Copied to Clipboard") drawn over the top of the
/// page. A view inside the browser window, never a window of its own: it
/// can appear while the omnibox is being edited (ordering a window on screen
/// then crashes AppKit -- see CLAUDE.md), and it never takes focus or a
/// click, so whatever the user was doing carries on underneath it.
final class WindowToast {
    private let view = ToastView()
    private var hideWorkItem: DispatchWorkItem?

    /// `topY` is the y (in `container`'s coordinates) of the top of the page
    /// area; the toast hangs just below it, centred.
    func show(_ message: String, symbolName: String? = nil, in container: NSView, belowY topY: CGFloat) {
        view.configure(message: message, symbolName: symbolName)
        let size = view.fittingSize
        view.frame = NSRect(
            x: ((container.bounds.width - size.width) / 2).rounded(),
            y: (topY - size.height - 12).rounded(),
            width: size.width, height: size.height)
        view.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        if view.superview !== container {
            view.removeFromSuperview()
            view.alphaValue = 0
            container.addSubview(view)
        } else {
            // Kept on top of anything added since it was last shown.
            container.addSubview(view, positioned: .above, relativeTo: nil)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            view.animator().alphaValue = 1
        }
        hideWorkItem?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                self.view.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.view.alphaValue == 0 else { return }
                self.view.removeFromSuperview()
            })
        }
        hideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: hide)
    }
}

private final class ToastView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        icon.contentTintColor = .secondaryLabelColor
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        stack.setViews([icon, label], in: .leading)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(message: String, symbolName: String?) {
        label.stringValue = message
        icon.image = symbolName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.isHidden = icon.image == nil
        setAccessibilityLabel(message)
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// Never the target of a click: the page or chrome underneath gets it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
