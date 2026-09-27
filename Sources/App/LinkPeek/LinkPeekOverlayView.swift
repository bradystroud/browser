import AppKit

/// The peek's views: a still of the page underneath, dimmed, and a rounded
/// panel over it with a header (title, Open as Tab, close) above the peeked
/// tab's hostView. The still stands in for the covered page, whose engine
/// view is detached while the peek shows -- see LinkPeekController.
final class LinkPeekOverlayView: NSView {
    var onClickOutside: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenAsTab: (() -> Void)?

    private static let headerHeight: CGFloat = 38
    private static let cornerRadius: CGFloat = 12

    /// Carries the shadow; `clipView` inside it does the rounding, since a
    /// layer that masks to its bounds also clips its own shadow away.
    private let panel = NSView()
    private let backdrop: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently
        view.autoresizingMask = [.width, .height]
        return view
    }()
    private let dimView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        return view
    }()
    private let clipView = NSView()
    private let header = LinkPeekHeaderView()
    private let pageHost = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private lazy var openAsTabButton = Self.makeButton(
        title: "Open as Tab", symbol: "arrow.up.left.and.arrow.down.right",
        target: self, action: #selector(openAsTabClicked))
    private lazy var closeButton = Self.makeButton(
        title: nil, symbol: "xmark", target: self, action: #selector(closeClicked))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        backdrop.frame = bounds
        dimView.frame = bounds
        addSubview(backdrop)
        addSubview(dimView)

        panel.wantsLayer = true
        panel.shadow = {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            return shadow
        }()
        addSubview(panel)

        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = Self.cornerRadius
        clipView.layer?.masksToBounds = true
        clipView.layer?.borderWidth = 1
        panel.addSubview(clipView)

        pageHost.wantsLayer = true
        clipView.addSubview(pageHost)
        clipView.addSubview(header)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        hostLabel.font = .systemFont(ofSize: 12)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingMiddle
        closeButton.toolTip = "Close Peek (Esc)"
        openAsTabButton.toolTip = "Keep this page as a tab"
        closeButton.setAccessibilityLabel("Close Peek")
        for view in [titleLabel, hostLabel, openAsTabButton, closeButton] {
            header.addSubview(view)
        }

        setAccessibilityRole(.group)
        setAccessibilityLabel("Link Peek")
        layoutPanel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The picture of the covered page shown behind the dimming.
    func setBackdrop(_ image: NSImage?) {
        backdrop.image = image
    }

    /// Puts the peeked tab's hostView into the panel, filling it.
    func embed(_ hostView: NSView) {
        hostView.removeFromSuperview()
        hostView.frame = pageHost.bounds
        hostView.autoresizingMask = [.width, .height]
        pageHost.addSubview(hostView)
    }

    func update(title: String, urlString: String) {
        let host = URL(string: urlString)?.host ?? urlString
        titleLabel.stringValue = title.isEmpty ? host : title
        hostLabel.stringValue = host
        layoutHeader()
    }

    // MARK: - Layout

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutPanel()
    }

    private func layoutPanel() {
        let horizontalMargin = max(24, (bounds.width * 0.07).rounded())
        let verticalMargin: CGFloat = 20
        panel.frame = bounds.insetBy(dx: horizontalMargin, dy: verticalMargin)
        clipView.frame = panel.bounds
        let headerHeight = Self.headerHeight
        header.frame = NSRect(x: 0, y: clipView.bounds.height - headerHeight, width: clipView.bounds.width, height: headerHeight)
        pageHost.frame = NSRect(x: 0, y: 0, width: clipView.bounds.width, height: max(0, clipView.bounds.height - headerHeight))
        layoutHeader()
    }

    private func layoutHeader() {
        let bounds = header.bounds
        let inset: CGFloat = 10
        let closeSize: CGFloat = 26
        closeButton.frame = NSRect(x: bounds.width - inset - closeSize, y: (bounds.height - closeSize) / 2, width: closeSize, height: closeSize)
        openAsTabButton.sizeToFit()
        let openWidth = openAsTabButton.frame.width + 12
        openAsTabButton.frame = NSRect(
            x: closeButton.frame.minX - 6 - openWidth, y: (bounds.height - closeSize) / 2,
            width: openWidth, height: closeSize)

        let textMaxX = openAsTabButton.frame.minX - 12
        let hostWidth = min(hostLabel.intrinsicContentSize.width, max(0, (textMaxX - inset) * 0.4))
        titleLabel.sizeToFit()
        let titleWidth = min(titleLabel.frame.width, max(0, textMaxX - inset - hostWidth - 8))
        let labelHeight = titleLabel.frame.height
        let labelY = (bounds.height - labelHeight) / 2
        titleLabel.frame = NSRect(x: inset + 4, y: labelY, width: titleWidth, height: labelHeight)
        hostLabel.frame = NSRect(x: titleLabel.frame.maxX + 8, y: labelY, width: hostWidth, height: labelHeight)
    }

    // MARK: - Appearance

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolved against this view's own appearance, so dark mode follows
        // the window rather than whatever appearance was current at init.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
            clipView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            clipView.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - Events

    /// Clicks on the panel's own header land here too (NSView passes an
    /// unhandled mouseDown up to its superview), so only a click that is
    /// actually outside the panel dismisses it.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if panel.frame.contains(point) {
            // A click on the header moves focus off the page, so Escape then
            // reaches the peek rather than the page.
            window?.makeFirstResponder(self)
        } else {
            onClickOutside?()
        }
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func openAsTabClicked() { onOpenAsTab?() }
    @objc private func closeClicked() { onClose?() }

    private static func makeButton(title: String?, symbol: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? "Close")
        let button: NSButton
        if let title {
            button = NSButton(title: title, image: image ?? NSImage(), target: target, action: action)
            button.imagePosition = .imageLeading
        } else {
            button = NSButton(image: image ?? NSImage(), target: target, action: action)
        }
        button.bezelStyle = .recessed
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        return button
    }
}

/// The panel's header strip; draws its own background and bottom hairline.
private final class LinkPeekHeaderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            hairline.backgroundColor = NSColor.separatorColor.cgColor
        }
        if hairline.superlayer == nil { layer?.addSublayer(hairline) }
        hairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }

    private let hairline = CALayer()

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        hairline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }
}
