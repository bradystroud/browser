import AppKit

/// A row of clickable circular color swatches, used by the "New Profile…"
/// prompt. Selection is drawn as a ring around the chosen swatch; there is
/// always exactly one selected swatch once `hexValues` is non-empty.
final class ColorSwatchPicker: NSView {
    private let hexValues: [String]
    private var buttons: [SwatchButton] = []
    private(set) var selectedIndex: Int

    var selectedHex: String { hexValues[selectedIndex] }

    static let swatchDiameter: CGFloat = 24
    static let spacing: CGFloat = 8

    init(hexValues: [String], initialSelection: Int = 0) {
        self.hexValues = hexValues
        self.selectedIndex = min(initialSelection, max(hexValues.count - 1, 0))
        let width = CGFloat(hexValues.count) * Self.swatchDiameter
            + CGFloat(max(hexValues.count - 1, 0)) * Self.spacing
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.swatchDiameter))
        buildButtons()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func buildButtons() {
        for (index, hex) in hexValues.enumerated() {
            let button = SwatchButton(hex: hex)
            button.frame = NSRect(
                x: CGFloat(index) * (Self.swatchDiameter + Self.spacing),
                y: 0,
                width: Self.swatchDiameter,
                height: Self.swatchDiameter
            )
            button.target = self
            button.tag = index
            button.action = #selector(swatchTapped(_:))
            button.isSelected = index == selectedIndex
            addSubview(button)
            buttons.append(button)
        }
    }

    @objc private func swatchTapped(_ sender: SwatchButton) {
        selectedIndex = sender.tag
        for (index, button) in buttons.enumerated() {
            button.isSelected = index == selectedIndex
        }
    }
}

private final class SwatchButton: NSButton {
    let hex: String
    var isSelected: Bool = false {
        didSet { needsDisplay = true }
    }

    init(hex: String) {
        self.hex = hex
        super.init(frame: .zero)
        isBordered = false
        title = ""
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = isSelected ? 3 : 0
        let circleRect = bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(ovalIn: circleRect)
        (NSColor(hex: hex) ?? .controlAccentColor).setFill()
        path.fill()

        if isSelected {
            let ringPath = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ringPath.lineWidth = 2
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            ringPath.stroke()
        }
    }
}
