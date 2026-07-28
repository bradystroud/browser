import AppKit

/// One tab's cell in the Tab Overview grid (browser-rhi.3): a captured page
/// thumbnail with a small favicon+title strip beneath it, or -- for a tab
/// with no cached thumbnail yet (never activated/deactivated this session,
/// e.g. a lazy-restored background tab whose CefBrowser was never even
/// created) -- a large centered favicon glyph with the title beneath
/// instead, per the task's own "favicon+title placeholder" wording.
final class TabOverviewCellView: NSView {
    let tabId: UUID
    var onSelect: (() -> Void)?

    private static let genericFavicon = NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")

    private let thumbnailView = NSImageView()
    private let placeholderFaviconView = NSImageView()
    private let stripFaviconView = NSImageView()
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        label.alignment = .center
        return label
    }()

    private var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            layer?.borderWidth = isSelected ? 2 : 0
        }
    }

    init(tabId: UUID, title: String, favicon: NSImage?, thumbnail: NSImage?) {
        self.tabId = tabId
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 6
        thumbnailView.layer?.masksToBounds = true
        addSubview(thumbnailView)

        placeholderFaviconView.image = favicon ?? Self.genericFavicon
        placeholderFaviconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(placeholderFaviconView)

        stripFaviconView.image = favicon ?? Self.genericFavicon
        stripFaviconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(stripFaviconView)

        titleLabel.stringValue = title
        addSubview(titleLabel)

        setThumbnail(thumbnail)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setHighlighted(_ highlighted: Bool) {
        isSelected = highlighted
    }

    private func setThumbnail(_ thumbnail: NSImage?) {
        thumbnailView.image = thumbnail
        thumbnailView.isHidden = thumbnail == nil
        placeholderFaviconView.isHidden = thumbnail != nil
        stripFaviconView.isHidden = thumbnail == nil
    }

    override func layout() {
        super.layout()
        let margin: CGFloat = 8
        let titleHeight: CGFloat = 16
        let stripHeight: CGFloat = thumbnailView.isHidden ? 0 : 18
        let faviconSize: CGFloat = 14

        titleLabel.frame = NSRect(x: margin, y: margin, width: max(0, bounds.width - margin * 2), height: titleHeight)

        if !thumbnailView.isHidden {
            stripFaviconView.frame = NSRect(
                x: margin, y: margin + titleHeight, width: faviconSize, height: faviconSize)
            thumbnailView.frame = NSRect(
                x: margin, y: margin + titleHeight + stripHeight,
                width: max(0, bounds.width - margin * 2),
                height: max(0, bounds.height - margin * 2 - titleHeight - stripHeight))
            placeholderFaviconView.frame = .zero
        } else {
            let placeholderSize: CGFloat = min(bounds.width, bounds.height) * 0.35
            placeholderFaviconView.frame = NSRect(
                x: (bounds.width - placeholderSize) / 2,
                y: margin + titleHeight + (bounds.height - margin * 2 - titleHeight - placeholderSize) / 2,
                width: placeholderSize, height: placeholderSize)
            thumbnailView.frame = .zero
            stripFaviconView.frame = .zero
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
