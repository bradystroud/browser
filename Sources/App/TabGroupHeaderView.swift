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

    var memberCount = 0 {
        didSet {
            guard oldValue != memberCount else { return }
            updateChevronAndBadge()
        }
    }

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
        layer?.cornerRadius = 6

        colorDotView.wantsLayer = true
        colorDotView.layer?.cornerRadius = 4
        addSubview(colorDotView)

        nameLabel.stringValue = name
        addSubview(nameLabel)

        chevronView.imageScaling = .scaleProportionallyDown
        addSubview(chevronView)

        addSubview(countBadgeLabel)

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
        layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
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
        if isCollapsed {
            let badgeWidth: CGFloat = 18
            countBadgeLabel.frame = NSRect(x: bounds.width - chevronSize - badgeWidth - 8, y: 0, width: badgeWidth, height: bounds.height)
            trailingReserved += badgeWidth + 2
        } else {
            countBadgeLabel.frame = .zero
        }
        nameLabel.frame = NSRect(x: labelX, y: 0, width: max(0, bounds.width - labelX - trailingReserved), height: bounds.height)
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
