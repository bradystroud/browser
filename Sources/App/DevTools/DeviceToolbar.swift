import AppKit

/// One tab's Responsive Design Mode, driven the way Chrome's device toolbar
/// is: a bar above the page (not over it) with a device menu, editable
/// width × height, a device-pixel-ratio menu, rotate and close. The View >
/// Responsive Design Mode menu and ⇧⌘M act on the same per-tab state, so
/// every entry point stays in sync.
final class DeviceToolbarController {
    private weak var tab: Tab?

    private(set) var isOn = false
    /// The chosen device; nil is "Responsive", whose size is edited freely.
    private(set) var preset: ResponsiveDevicePreset?
    private(set) var width = 0
    private(set) var height = 0
    private(set) var scale: Double = 1
    private var mobile = false

    private lazy var toolbar = DeviceToolbarView(controller: self)

    static let dimensionRange = 50...9999
    static let scales: [Double] = [1, 2, 3]

    init(tab: Tab) {
        self.tab = tab
    }

    private var isSupported: Bool { ActiveEngine.capabilities.responsiveDesignMode }

    /// ⇧⌘M: on with this tab's last choice (Responsive the first time), or off.
    func toggle() {
        if isOn {
            turnOff()
        } else if let preset {
            select(preset, keepingOrientation: true)
        } else {
            selectResponsive()
        }
    }

    func select(_ preset: ResponsiveDevicePreset, keepingOrientation: Bool = false) {
        guard isSupported else { return }
        let landscape = keepingOrientation && self.preset?.name == preset.name && width > height
        self.preset = preset
        width = landscape ? preset.height : preset.width
        height = landscape ? preset.width : preset.height
        scale = preset.deviceScaleFactor
        mobile = preset.mobile
        apply()
    }

    /// Responsive: the size last shown, or the page's own size the first time.
    func selectResponsive() {
        guard isSupported else { return }
        if width == 0 || height == 0, let page = tab?.devTools.pageView.bounds.size {
            width = Int(page.width.rounded())
            height = Int((page.height - (isOn ? 0 : DeviceToolbarView.height)).rounded())
            scale = Double(tab?.devTools.pageView.window?.backingScaleFactor ?? 2)
        }
        preset = nil
        mobile = false
        width = Self.clamp(width)
        height = Self.clamp(height)
        apply()
    }

    func setSize(width: Int, height: Int) {
        guard isOn else { return }
        preset = nil
        mobile = false
        self.width = Self.clamp(width)
        self.height = Self.clamp(height)
        apply()
    }

    func setScale(_ scale: Double) {
        guard isOn else { return }
        self.scale = scale
        apply()
    }

    func rotate() {
        guard isOn else { return }
        swap(&width, &height)
        apply()
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        tab?.clearResponsiveDesignMode()
        tab?.devTools.setPageToolbar(nil)
    }

    private func apply() {
        guard let tab else { return }
        isOn = true
        tab.devTools.setPageToolbar(toolbar)
        tab.setResponsiveDesignMode(width: width, height: height, deviceScaleFactor: scale, mobile: mobile)
        toolbar.update(from: self)
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, dimensionRange.lowerBound), dimensionRange.upperBound)
    }
}

/// The device toolbar's controls, centred like Chrome's, with the close
/// button at the trailing edge.
final class DeviceToolbarView: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 30

    private weak var controller: DeviceToolbarController?
    private let devicePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let widthField = NSTextField()
    private let heightField = NSTextField()
    private let scalePopUp = NSPopUpButton(frame: .zero, pullsDown: false)

    init(controller: DeviceToolbarController) {
        self.controller = controller
        super.init(frame: .zero)

        devicePopUp.addItem(withTitle: "Responsive")
        devicePopUp.menu?.addItem(.separator())
        for preset in ResponsiveDevicePreset.all {
            devicePopUp.addItem(withTitle: preset.name)
            devicePopUp.lastItem?.representedObject = preset
        }
        devicePopUp.target = self
        devicePopUp.action = #selector(deviceChosen(_:))
        devicePopUp.toolTip = "Device"

        for field in [widthField, heightField] {
            field.alignment = .center
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            field.controlSize = .small
            field.bezelStyle = .roundedBezel
            field.delegate = self
            field.target = self
            field.action = #selector(sizeEntered(_:))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 56).isActive = true
        }
        widthField.toolTip = "Width"
        heightField.toolTip = "Height"
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor

        for scale in DeviceToolbarController.scales {
            scalePopUp.addItem(withTitle: "DPR: \(Self.format(scale))")
            scalePopUp.lastItem?.representedObject = scale
        }
        scalePopUp.target = self
        scalePopUp.action = #selector(scaleChosen(_:))
        scalePopUp.toolTip = "Device pixel ratio"

        for popUp in [devicePopUp, scalePopUp] {
            popUp.controlSize = .small
            popUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            popUp.isBordered = false
        }

        let rotate = Self.iconButton(symbol: "rectangle.portrait.rotate", label: "Rotate", target: self, action: #selector(rotateClicked(_:)))
        let close = Self.iconButton(symbol: "xmark", label: "Close Device Toolbar", target: self, action: #selector(closeClicked(_:)))

        let controls = NSStackView(views: [devicePopUp, widthField, times, heightField, scalePopUp, rotate])
        controls.spacing = 6
        controls.setCustomSpacing(12, after: devicePopUp)
        controls.setCustomSpacing(12, after: heightField)
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        addSubview(close)
        let centred = controls.centerXAnchor.constraint(equalTo: centerXAnchor)
        centred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            centred,
            controls.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            controls.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Device Toolbar")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    func update(from controller: DeviceToolbarController) {
        if let preset = controller.preset,
           let item = devicePopUp.itemArray.first(where: { ($0.representedObject as? ResponsiveDevicePreset)?.name == preset.name }) {
            devicePopUp.select(item)
        } else {
            devicePopUp.selectItem(at: 0)
        }
        widthField.integerValue = controller.width
        heightField.integerValue = controller.height
        // A device's size and pixel ratio are the device's own, as in Chrome.
        let responsive = controller.preset == nil
        widthField.isEnabled = responsive
        heightField.isEnabled = responsive
        scalePopUp.isEnabled = responsive
        if let index = scalePopUp.itemArray.firstIndex(where: { ($0.representedObject as? Double) == controller.scale }) {
            scalePopUp.selectItem(at: index)
        } else {
            scalePopUp.addItem(withTitle: "DPR: \(Self.format(controller.scale))")
            scalePopUp.lastItem?.representedObject = controller.scale
            scalePopUp.select(scalePopUp.lastItem)
        }
    }

    private static func format(_ scale: Double) -> String {
        scale == scale.rounded() ? String(Int(scale)) : String(scale)
    }

    private static func iconButton(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "square", accessibilityDescription: label)!
        let button = NSButton(image: image, target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.refusesFirstResponder = true
        return button
    }

    @objc private func deviceChosen(_ sender: NSPopUpButton) {
        if let preset = sender.selectedItem?.representedObject as? ResponsiveDevicePreset {
            controller?.select(preset)
        } else {
            controller?.selectResponsive()
        }
    }

    @objc private func sizeEntered(_ sender: NSTextField) {
        guard let controller else { return }
        let width = widthField.integerValue > 0 ? widthField.integerValue : controller.width
        let height = heightField.integerValue > 0 ? heightField.integerValue : controller.height
        guard width != controller.width || height != controller.height else { return }
        controller.setSize(width: width, height: height)
    }

    @objc private func scaleChosen(_ sender: NSPopUpButton) {
        guard let scale = sender.selectedItem?.representedObject as? Double else { return }
        controller?.setScale(scale)
    }

    @objc private func rotateClicked(_ sender: Any?) {
        controller?.rotate()
    }

    @objc private func closeClicked(_ sender: Any?) {
        controller?.turnOff()
    }

    /// Up/down arrows step a size field by 1, or 10 with Shift, as in Chrome.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField,
              selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)) else { return false }
        let step = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
        let delta = selector == #selector(NSResponder.moveUp(_:)) ? step : -step
        field.integerValue = max(field.integerValue + delta, DeviceToolbarController.dimensionRange.lowerBound)
        sizeEntered(field)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        DevToolsPaneHeaderView.toolbarColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {}
}
