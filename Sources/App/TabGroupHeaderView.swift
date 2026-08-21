import AppKit

/// One tab group's header in the strip: a colored pill with the group's
/// name, an expand/collapse chevron (or a tab-count badge once collapsed),
/// clickable to toggle, right-click for Rename/Change Color/Ungroup All/
/// Close Group. It never becomes "selected" the way a TabButtonView does --
/// the strip's selection highlight only ever lands on an actual tab.
final class TabGroupHeaderView: NSView {
    let groupId: UUID
    var onToggleCollapse: (() -> Void)?
    var onRename: (() -> Void)?
    var onChangeColor: (() -> Void)?
    var onUngroupAll: (() -> Void)?
    var onCloseGroup: (() -> Void)?

    var isCollapsed = false {
        didSet {
            guard oldValue != isCollapsed else { return }
            updateChevronAndBadge()
            needsLayout = true
        }
    }

    /// True while this header is a full-width row in the vertical sidebar --
    /// see TabButtonView.isVerticalLayout for why the capsule radius does not
    /// survive that change of proportions.
    var isVerticalLayout = false {
        didSet {
            guard oldValue != isVerticalLayout else { return }
            needsLayout = true
        }
    }

    var memberCount = 0 {
        didSet {
            guard oldValue != memberCount else { return }
            updateChevronAndBadge()
        }
    }

    /// `NSGlassEffectView` on macOS 26+ -- see GlassBackgroundView's own doc
    /// comment on why this is stored untyped. `nil` pre-26, in which case
    /// setColorHex(_:) falls back to its original layer.backgroundColor
    /// tint, unchanged from before this rework.
    private var glassBackground: NSView?

    /// Real content lives here, not directly on `self` -- see
    /// TabButtonView.contentContainer's own doc comment (browser-0y1) for
    /// why a plain sibling subview of the glass view isn't guaranteed
    /// correct z-ordering.
    private let contentContainer = NSView()

    private let colorDotView = NSView()
    private let nameLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .labelColor
        return label
    }()
    private let chevronView = NSImageView()
    private let countBadgeLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.isHidden = true
        return label
    }()

    init(groupId: UUID, name: String, colorHex: String) {
        self.groupId = groupId
        super.init(frame: .zero)
        wantsLayer = true

        colorDotView.wantsLayer = true
        colorDotView.layer?.cornerRadius = 4
        contentContainer.addSubview(colorDotView)

        nameLabel.stringValue = name
        contentContainer.addSubview(nameLabel)

        chevronView.imageScaling = .scaleProportionallyDown
        contentContainer.addSubview(chevronView)

        contentContainer.addSubview(countBadgeLabel)

        // Real Liquid Glass material for the header pill (browser-qpy
        // rework), hosting contentContainer as its contentView so the
        // dot/name/chevron above are guaranteed to render on top of the
        // glass effect rather than composited underneath it (browser-0y1);
        // setColorHex(_:) below rides its tintColor property instead of the
        // plain layer.backgroundColor tint pre-26 uses.
        contentContainer.frame = bounds
        contentContainer.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.autoresizingMask = [.width, .height]
            glass.style = .regular
            glass.contentView = contentContainer
            addSubview(glass)
            glassBackground = glass
        } else {
            addSubview(contentContainer)
        }

        setColorHex(colorHex)
        updateChevronAndBadge()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func setName(_ name: String) {
        nameLabel.stringValue = name
    }

    func setColorHex(_ colorHex: String) {
        let color = NSColor(hex: colorHex) ?? .controlAccentColor
        if #available(macOS 26.0, *), let glass = glassBackground as? NSGlassEffectView {
            glass.tintColor = color
        } else {
            layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        }
        colorDotView.layer?.backgroundColor = color.cgColor
    }

    private func updateChevronAndBadge() {
        chevronView.image = NSImage(
            systemSymbolName: isCollapsed ? "chevron.right" : "chevron.down",
            accessibilityDescription: isCollapsed ? "Expand" : "Collapse"
        )
        countBadgeLabel.stringValue = "\(memberCount)"
        countBadgeLabel.isHidden = !isCollapsed
    }

    override func layout() {
        super.layout()
        // Full pill shape (browser-qpy), matching TabButtonView -- see that
        // view's own layout() for why the real glass view masks its own
        // corners on macOS 26+ instead of this view's layer.
        let cornerRadius = isVerticalLayout ? min(9, bounds.height / 2) : bounds.height / 2
        if #available(macOS 26.0, *), let glass = glassBackground as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else {
            layer?.cornerRadius = cornerRadius
        }
        let dotSize: CGFloat = 8
        let margin: CGFloat = 8
        let chevronSize: CGFloat = 10

        colorDotView.frame = NSRect(x: margin, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
        chevronView.frame = NSRect(
            x: bounds.width - chevronSize - 6,
            y: (bounds.height - chevronSize) / 2,
            width: chevronSize,
            height: chevronSize
        )

        let labelX = margin + dotSize + 6
        var trailingReserved = chevronSize + 6
        // Vertically centered as their own row alongside the dot/chevron
        // above (browser-0y1) -- see TabButtonView.layout()'s own comment
        // for why a fixed label height centered in bounds.height is needed
        // instead of a full-height frame (which top-aligns the text).
        let labelHeight: CGFloat = 16
        if isCollapsed {
            let badgeWidth: CGFloat = 18
            countBadgeLabel.frame = NSRect(
                x: bounds.width - chevronSize - badgeWidth - 8, y: (bounds.height - labelHeight) / 2,
                width: badgeWidth, height: labelHeight
            )
            trailingReserved += badgeWidth + 2
        } else {
            countBadgeLabel.frame = .zero
        }
        nameLabel.frame = NSRect(
            x: labelX, y: (bounds.height - labelHeight) / 2,
            width: max(0, bounds.width - labelX - trailingReserved), height: labelHeight
        )
    }

    override func mouseDown(with event: NSEvent) {
        onToggleCollapse?()
    }

    /// Right-click/Control-click context menu -- built fresh each time (not
    /// kept as a stored menu) so it doesn't need to be invalidated on every
    /// rename/recolor. Minimal per scope: Rename, Change Color, Ungroup All,
    /// Close Group -- no submenus, no icons.
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename", action: #selector(renameTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Change Color", action: #selector(changeColorTapped), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ungroup All", action: #selector(ungroupAllTapped), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close Group", action: #selector(closeGroupTapped), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func renameTapped() { onRename?() }
    @objc private func changeColorTapped() { onChangeColor?() }
    @objc private func ungroupAllTapped() { onUngroupAll?() }
    @objc private func closeGroupTapped() { onCloseGroup?() }
}
