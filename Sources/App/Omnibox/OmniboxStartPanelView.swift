import AppKit

/// One tile in the omnibox start panel: a rounded icon square above a short
/// caption, Safari-style. The icon is the site's real favicon when
/// FaviconLoader can produce one (usually instantly -- it has both an
/// in-memory and a per-profile on-disk cache from ordinary browsing), with a
/// colored monogram of the title's first letter as the standing fallback, the
/// same fallback the HTML start page uses for every tile.
///
/// A plain NSView rather than an NSButton because the click needs its
/// modifier flags (⌘/⌘⇧ open in a new tab -- see
/// docs/ai-tasks/link-click-new-tab-notes.md for the same convention on real
/// link clicks) and NSButton's action carries none.
final class OmniboxStartPanelTileView: NSView {
    static let width: CGFloat = 84
    static let iconSize: CGFloat = 52
    private static let captionHeight: CGFloat = 16
    private static let captionGap: CGFloat = 6
    static let height: CGFloat = iconSize + captionGap + captionHeight

    /// Called on a completed click inside the tile, with the modifier flags
    /// live at mouse-up.
    var onActivate: ((NSEvent.ModifierFlags) -> Void)?

    private let tile: StartPageTile
    private let iconContainer = NSView()
    private let monogramLabel = NSTextField(labelWithString: "")
    private let iconImageView = NSImageView()
    private let captionLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var isPressed = false

    init(tile: StartPageTile, profileId: String) {
        self.tile = tile
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        toolTip = tile.url

        iconContainer.wantsLayer = true
        iconContainer.layer?.cornerRadius = 12
        iconContainer.frame = NSRect(
            x: (Self.width - Self.iconSize) / 2, y: 0,
            width: Self.iconSize, height: Self.iconSize
        )
        addSubview(iconContainer)

        let monogramSource = tile.title.trimmingCharacters(in: .whitespacesAndNewlines)
        monogramLabel.stringValue = monogramSource.isEmpty ? "?" : String(monogramSource.prefix(1)).uppercased()
        monogramLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        monogramLabel.textColor = .labelColor
        monogramLabel.alignment = .center
        monogramLabel.frame = NSRect(x: 0, y: (Self.iconSize - 24) / 2, width: Self.iconSize, height: 24)
        iconContainer.addSubview(monogramLabel)

        iconImageView.frame = NSRect(x: 10, y: 10, width: Self.iconSize - 20, height: Self.iconSize - 20)
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.isHidden = true
        iconContainer.addSubview(iconImageView)

        captionLabel.stringValue = tile.title
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .labelColor
        captionLabel.alignment = .center
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.frame = NSRect(
            x: 0, y: Self.iconSize + Self.captionGap,
            width: Self.width, height: Self.captionHeight
        )
        addSubview(captionLabel)

        applyBackground()
        loadFavicon(profileId: profileId)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The panel view is flipped (top-down layout, see
    /// OmniboxStartPanelView) -- match it so this tile's own subview frames
    /// read top-down too.
    override var isFlipped: Bool { true }

    private func loadFavicon(profileId: String) {
        guard let host = URL(string: tile.url)?.host, !host.isEmpty else { return }
        // The cached case is resolved before the panel is ever drawn, so an
        // already-known site never shows its monogram for a frame and then
        // swaps -- FaviconLoader's async path always calls back at least one
        // run-loop turn later, even on a hit.
        if let cached = FaviconLoader.shared.cachedFaviconImage(host: host, profileId: profileId) {
            showFavicon(cached)
            return
        }
        FaviconLoader.shared.loadFavicon(host: host, hintURL: nil, profileId: profileId) { [weak self] image in
            guard let self, let image else { return }
            self.showFavicon(image)
        }
    }

    private func showFavicon(_ image: NSImage) {
        iconImageView.image = image
        iconImageView.isHidden = false
        monogramLabel.isHidden = true
    }

    // MARK: - Hover / press feedback

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        applyBackground()
    }

    private func applyBackground() {
        let alpha: CGFloat = isPressed ? 0.35 : (isHovered ? 0.22 : 0.12)
        // labelColor-derived rather than a fixed gray so the tile reads
        // correctly in both light and dark appearance, and under Reduce
        // Transparency's solid panel fallback.
        iconContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
    }

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        applyBackground()
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        applyBackground()
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onActivate?(event.modifierFlags)
    }
}

/// The omnibox start panel's content: the same sections the HTML start page
/// shows (StartPageSections), laid out as native tile grids. Sized once, at
/// construction, for a fixed width -- `frame.height` after init is the exact
/// height the content needs, which the controller uses to size the panel (and
/// to decide whether it has to scroll).
///
/// Manual frames, not Auto Layout: this codebase's chrome is manual-frame
/// throughout, and a fixed-width grid's arithmetic is trivial and lets the
/// fitting height fall straight out of the layout pass.
final class OmniboxStartPanelView: NSView {
    private static let horizontalPadding: CGFloat = 18
    private static let verticalPadding: CGFloat = 16
    private static let tileGap: CGFloat = 8
    private static let headerHeight: CGFloat = 15
    private static let headerGap: CGFloat = 10
    private static let sectionGap: CGFloat = 20
    private static let emptyMessageHeight: CGFloat = 17

    /// Called when a tile is clicked, with the URL and the click's modifier
    /// flags (⌘ = new tab, ⌘⇧ = new foreground tab).
    private let onSelect: (String, NSEvent.ModifierFlags) -> Void

    init(
        sections: [StartPageSection],
        profileId: String,
        width: CGFloat,
        onSelect: @escaping (String, NSEvent.ModifierFlags) -> Void
    ) {
        self.onSelect = onSelect
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        let height = build(sections: sections, profileId: profileId, width: width)
        frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func build(sections: [StartPageSection], profileId: String, width: CGFloat) -> CGFloat {
        let contentWidth = width - Self.horizontalPadding * 2
        var y = Self.verticalPadding

        for (index, section) in sections.enumerated() {
            let header = NSTextField(labelWithString: section.title.uppercased())
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            header.frame = NSRect(x: Self.horizontalPadding, y: y, width: contentWidth, height: Self.headerHeight)
            addSubview(header)
            y += Self.headerHeight + Self.headerGap

            if section.tiles.isEmpty {
                let message = NSTextField(labelWithString: section.emptyMessage)
                message.font = .systemFont(ofSize: 12)
                // secondary, not tertiary: this sits on translucent glass
                // over whatever page is behind it, where tertiary washed out
                // to near-unreadable against a bright start page.
                message.textColor = .secondaryLabelColor
                message.lineBreakMode = .byTruncatingTail
                message.frame = NSRect(
                    x: Self.horizontalPadding, y: y,
                    width: contentWidth, height: Self.emptyMessageHeight
                )
                addSubview(message)
                y += Self.emptyMessageHeight
            } else {
                y += layoutGrid(
                    tiles: section.tiles, profileId: profileId,
                    topY: y, contentWidth: contentWidth
                )
            }

            if index < sections.count - 1 {
                y += Self.sectionGap
            }
        }

        return y + Self.verticalPadding
    }

    /// Lays a section's tiles out into as many columns as `contentWidth`
    /// fits, left-aligned, and returns the grid's own total height.
    private func layoutGrid(
        tiles: [StartPageTile], profileId: String, topY: CGFloat, contentWidth: CGFloat
    ) -> CGFloat {
        let tileWidth = OmniboxStartPanelTileView.width
        let tileHeight = OmniboxStartPanelTileView.height
        let columns = max(1, Int((contentWidth + Self.tileGap) / (tileWidth + Self.tileGap)))

        for (index, tile) in tiles.enumerated() {
            let column = index % columns
            let row = index / columns
            let view = OmniboxStartPanelTileView(tile: tile, profileId: profileId)
            view.frame = NSRect(
                x: Self.horizontalPadding + CGFloat(column) * (tileWidth + Self.tileGap),
                y: topY + CGFloat(row) * (tileHeight + Self.tileGap),
                width: tileWidth, height: tileHeight
            )
            view.onActivate = { [weak self] modifiers in
                self?.onSelect(tile.url, modifiers)
            }
            addSubview(view)
        }

        let rows = (tiles.count + columns - 1) / columns
        return CGFloat(rows) * (tileHeight + Self.tileGap) - Self.tileGap
    }
}
