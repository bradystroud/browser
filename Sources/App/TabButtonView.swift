import AppKit

/// One tab's visual representation in the strip: title + a close button that
/// only appears on hover (Safari-style), selected/unselected background.
final class TabButtonView: NSView {
    let index: Int
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
        }
    }

    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        return label
    }()

    private let closeButton: NSButton = {
        let button = NSButton()
        button.isBordered = false
        button.title = ""
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
        button.imageScaling = .scaleProportionallyDown
        button.isHidden = true
        return button
    }()

    private var trackingArea: NSTrackingArea?

    init(index: Int, title: String) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6

        titleLabel.stringValue = title
        addSubview(titleLabel)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    override func layout() {
        super.layout()
        let closeSize: CGFloat = 14
        closeButton.frame = NSRect(
            x: bounds.width - closeSize - 6,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
        titleLabel.frame = NSRect(x: 8, y: 0, width: max(0, bounds.width - closeSize - 16), height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeTapped() {
        onClose?()
    }

    override func draw(_ dirtyRect: NSRect) {
        (isSelected ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).setFill()
        dirtyRect.fill()
    }
}
