import AppKit

/// Small rounded "key" badge (e.g. "⌘T") used in the shortcuts overlay.
private final class KeyBadgeView: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            heightAnchor.constraint(equalToConstant: 22),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

/// Builds the "Keyboard Shortcuts" overlay panel: a lightweight, non-modal
/// floating NSPanel with a frosted (NSVisualEffectView) background, content
/// laid out with NSStackView + Auto Layout -- a deliberate, contained
/// exception to this codebase's usual manual-frame chrome, since a static,
/// variable-length list of rows is exactly what Auto Layout is good at and
/// the payoff isn't worth it for one-off content like this. Shown/dismissed
/// by ShortcutsOverlayController, which owns the panel's lifecycle.
enum ShortcutsOverlayPanelFactory {
    private static let panelSize = NSSize(width: 460, height: 520)

    static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: panelSize))
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12

        let content = buildContentView()
        content.frame = effectView.bounds
        content.autoresizingMask = [.width, .height]
        effectView.addSubview(content)

        panel.contentView = effectView
        return panel
    }

    private static func buildContentView() -> NSView {
        let container = NSView()

        let titleLabel = NSTextField(labelWithString: "Keyboard Shortcuts")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)

        for (category, entries) in ShortcutsHelp.sections() {
            stack.addArrangedSubview(sectionView(title: category.title, entries: entries))
        }

        let footer = NSTextField(labelWithString: "Press Esc, click outside, or press ? again to close")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(footer)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
        ])
        return container
    }

    private static func sectionView(title: String, entries: [ShortcutEntry]) -> NSView {
        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 6

        let header = NSTextField(labelWithString: title.uppercased())
        header.font = .systemFont(ofSize: 11, weight: .bold)
        header.textColor = .secondaryLabelColor
        sectionStack.addArrangedSubview(header)

        for entry in entries {
            sectionStack.addArrangedSubview(rowView(for: entry))
        }
        return sectionStack
    }

    private static func rowView(for entry: ShortcutEntry) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let badge = KeyBadgeView(text: entry.key)
        let label = NSTextField(labelWithString: entry.title)
        label.font = .systemFont(ofSize: 13)

        row.addArrangedSubview(badge)
        row.addArrangedSubview(label)
        return row
    }
}
