import AppKit

/// Where developer tools dock and how big they are, remembered across tabs
/// and launches like Chrome's. Through AppPreferencesStore, so a
/// `--profiles-root` launch keeps its own copy.
enum DevToolsPreferences {
    private static let dockSideKey = "BrowserDevToolsDockSide"
    private static let bottomHeightKey = "BrowserDevToolsBottomHeight"
    private static let sideWidthKey = "BrowserDevToolsSideWidth"

    static var dockSide: DevToolsDockSide {
        get {
            AppPreferencesStore.current.string(forKey: dockSideKey).flatMap(DevToolsDockSide.init(rawValue:)) ?? .right
        }
        set { AppPreferencesStore.current.set(newValue.rawValue, forKey: dockSideKey) }
    }

    /// Height of tools docked to the bottom.
    static var bottomHeight: CGFloat {
        get { storedLength(bottomHeightKey) ?? 320 }
        set { AppPreferencesStore.current.set(Double(newValue), forKey: bottomHeightKey) }
    }

    /// Width of tools docked to the right or left.
    static var sideWidth: CGFloat {
        get { storedLength(sideWidthKey) ?? 520 }
        set { AppPreferencesStore.current.set(Double(newValue), forKey: sideWidthKey) }
    }

    private static func storedLength(_ key: String) -> CGFloat? {
        let value = AppPreferencesStore.current.double(forKey: key)
        return value > 0 ? CGFloat(value) : nil
    }
}

/// One tab's developer tools dock: splits the tab's content area between
/// the page and the tools, per tab, the way Chrome does. The engine draws
/// the page into `pageView` and, when it can dock, the tools into the tools
/// pane this controller hands it; this controller alone decides the sizes.
///
/// Because everything lives inside the tab's own host view, the tools
/// travel with the tab: switching tabs hides them with it, navigating keeps
/// them, closing the tab closes them (Tab.close() calls tabWillClose()).
final class DevToolsDockController {
    /// Where the engine puts the page's own view.
    let pageView = NSView()

    private let layoutView: DevToolsDockLayoutView
    private weak var engineTab: EngineTab?

    private(set) var isOpen = false
    /// This tab's side while open; the remembered preference while closed.
    private(set) var dockSide = DevToolsPreferences.dockSide
    /// What the engine was last told, so re-applying the same placement
    /// does not keep bringing the tools forward.
    private var appliedSide: DevToolsDockSide?

    init(hostView: NSView) {
        layoutView = DevToolsDockLayoutView(pageView: pageView)
        layoutView.frame = hostView.bounds
        layoutView.autoresizingMask = [.width, .height]
        hostView.addSubview(layoutView)
        layoutView.header.onDockSide = { [weak self] side in self?.setDockSide(side) }
        layoutView.header.onClose = { [weak self] in self?.close() }
    }

    /// The tab's engine side, once it exists.
    func attach(to engineTab: EngineTab) {
        self.engineTab = engineTab
    }

    /// The side the engine can actually honour. An engine without docking
    /// always uses its own window.
    private var effectiveSide: DevToolsDockSide {
        ActiveEngine.capabilities.devToolsDocking ? dockSide : .window
    }

    // MARK: - Commands

    func toggle() {
        if isOpen { close() } else { open(panel: .default) }
    }

    func open(panel: DevToolsPanel) {
        guard let engineTab else { return }
        guard ActiveEngine.capabilities.inAppDevTools else {
            // The engine explains where to inspect the page instead.
            engineTab.showDevTools(panel: panel, dockSide: .window, in: nil)
            return
        }
        dockSide = DevToolsPreferences.dockSide
        setOpen(true)
        place(panel: panel, force: true)
    }

    func close() {
        engineTab?.closeDevTools()
        setOpen(false)
    }

    /// Chrome's ⌥⌘C: open on Elements with the element picker on.
    func startElementPicker() {
        if !isOpen { open(panel: .elements) }
        engineTab?.startElementPicker()
    }

    /// Reveals the element at `point` (in the page view's coordinates).
    func inspectElement(at point: NSPoint) {
        open(panel: .elements)
        engineTab?.inspectElement(at: point)
    }

    /// A Dock Side menu choice for this tab; also remembered for the next open.
    func setDockSide(_ side: DevToolsDockSide) {
        DevToolsPreferences.dockSide = side
        dockSide = side
        guard isOpen else { return }
        layoutView.dockSide = effectiveSide
        place(panel: .default, force: false)
    }

    func tabWillClose() {
        if isOpen || engineTab?.isDevToolsOpen == true { engineTab?.closeDevTools() }
        setOpen(false)
    }

    // MARK: - Engine events

    /// The engine opened the tools itself (its own Inspect Element): claim
    /// them for this tab's dock. Runs inside the engine's callback, which
    /// the engine contract allows.
    func engineDidOpen() {
        guard !isOpen else { return }
        dockSide = DevToolsPreferences.dockSide
        setOpen(true)
        place(panel: .default, force: true)
    }

    func engineDidClose() {
        setOpen(false)
    }

    /// The user picked a side inside the tools' own UI; they have moved
    /// already, so only the layout follows.
    func engineDidRequestDockSide(_ side: DevToolsDockSide) {
        DevToolsPreferences.dockSide = side
        dockSide = side
        appliedSide = side
        layoutView.dockSide = effectiveSide
    }

    // MARK: - Layout

    private func setOpen(_ open: Bool) {
        isOpen = open
        if !open { appliedSide = nil }
        layoutView.dockSide = effectiveSide
        layoutView.isToolsVisible = open
    }

    /// Frames of the pane's parts and the engine's own view of the tools,
    /// for the debug launch option's log line.
    var layoutSummary: String {
        func frame(_ view: NSView) -> String { view.isHidden ? "hidden" : NSStringFromRect(view.frame) }
        return "open=\(isOpen) engineOpen=\(engineTab?.isDevToolsOpen == true) side=\(dockSide.rawValue) "
            + "page=\(frame(pageView)) tools=\(frame(layoutView.toolsView)) "
            + "toolsSubviews=\(layoutView.toolsView.subviews.count) header=\(frame(layoutView.header)) "
            + "pageToolbar=\(layoutView.pageToolbar.map(frame) ?? "none")"
    }

    /// Shows `toolbar` above the page, inside the tab, or removes it (nil).
    func setPageToolbar(_ toolbar: NSView?) {
        layoutView.pageToolbar = toolbar
    }

    /// Whether the given view is inside this tab's docked tools pane, so
    /// keyboard handling can let the tools have their own shortcuts.
    func toolsPaneContains(_ view: NSView) -> Bool {
        isOpen && view.isDescendant(of: layoutView.toolsView)
    }

    private func place(panel: DevToolsPanel, force: Bool) {
        let side = effectiveSide
        guard force || side != appliedSide else { return }
        appliedSide = side
        layoutView.layoutNow()
        engineTab?.showDevTools(panel: panel, dockSide: side, in: side == .window ? nil : layoutView.toolsView)
    }
}

/// Lays out the page, the tools pane and the divider between them by hand:
/// the engines' own views use autoresizing, not Auto Layout, and a plain
/// frame split keeps the page's view the only thing that resizes.
private final class DevToolsDockLayoutView: NSView {
    let toolsView = NSView()
    let header = DevToolsPaneHeaderView()
    private let pageView: NSView
    private let divider = DevToolsDividerView()

    /// Minimum sizes, so neither side can be dragged away entirely.
    private static let minimumToolsHeight: CGFloat = 120
    private static let minimumToolsWidth: CGFloat = 260
    private static let minimumPageLength: CGFloat = 160

    var dockSide: DevToolsDockSide = .right {
        didSet {
            header.dockSide = dockSide
            if dockSide != oldValue { layoutNow() }
        }
    }

    var isToolsVisible = false {
        didSet { if isToolsVisible != oldValue { layoutNow() } }
    }

    private var isDocked: Bool { isToolsVisible && dockSide != .window }

    init(pageView: NSView) {
        self.pageView = pageView
        super.init(frame: .zero)
        pageView.autoresizingMask = []
        toolsView.autoresizingMask = []
        addSubview(pageView)
        addSubview(toolsView)
        addSubview(header)
        addSubview(divider)
        header.dockSide = dockSide
        divider.onDrag = { [weak self] point in self?.dividerDragged(to: point) }
        divider.onDragEnd = { [weak self] in self?.rememberToolsLength() }
        layoutNow()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        layoutNow()
    }

    /// While dragging, the length lives here; it is saved on mouse-up.
    private var draggedLength: CGFloat?

    private var toolsLength: CGFloat {
        draggedLength ?? (dockSide == .bottom ? DevToolsPreferences.bottomHeight : DevToolsPreferences.sideWidth)
    }

    /// A bar across the top of the page's side of the split (the device
    /// toolbar), taken out of the page's height rather than drawn over it.
    var pageToolbar: NSView? {
        didSet {
            guard pageToolbar !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let pageToolbar { addSubview(pageToolbar) }
            layoutNow()
        }
    }

    func layoutNow() {
        layoutSplit()
        // Read live: the header only exists for tools without their own.
        let showsHeader = isDocked && !ActiveEngine.capabilities.devToolsHasOwnChrome
        header.isHidden = !showsHeader
        if showsHeader {
            let tools = toolsView.frame
            let height = min(DevToolsPaneHeaderView.height, tools.height)
            header.frame = NSRect(x: tools.minX, y: tools.maxY - height, width: tools.width, height: height)
            toolsView.frame = NSRect(x: tools.minX, y: tools.minY, width: tools.width, height: tools.height - height)
        }
        if let pageToolbar {
            let page = pageView.frame
            let height = min(pageToolbar.intrinsicContentSize.height, page.height)
            pageToolbar.frame = NSRect(x: page.minX, y: page.maxY - height, width: page.width, height: height)
            pageView.frame = NSRect(x: page.minX, y: page.minY, width: page.width, height: page.height - height)
        }
    }

    private func layoutSplit() {
        let bounds = self.bounds
        toolsView.isHidden = !isDocked
        divider.isHidden = !isDocked
        guard isDocked else {
            pageView.frame = bounds
            return
        }
        let separator: CGFloat = 1
        let grab = DevToolsDividerView.grabThickness
        switch dockSide {
        case .bottom:
            let length = clamp(toolsLength, total: bounds.height, minimum: Self.minimumToolsHeight)
            toolsView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: length)
            pageView.frame = NSRect(x: 0, y: length + separator, width: bounds.width, height: max(bounds.height - length - separator, 0))
            divider.frame = NSRect(x: 0, y: length + separator / 2 - grab / 2, width: bounds.width, height: grab)
            divider.isVertical = false
        case .right:
            let length = clamp(toolsLength, total: bounds.width, minimum: Self.minimumToolsWidth)
            toolsView.frame = NSRect(x: bounds.width - length, y: 0, width: length, height: bounds.height)
            pageView.frame = NSRect(x: 0, y: 0, width: max(bounds.width - length - separator, 0), height: bounds.height)
            divider.frame = NSRect(x: bounds.width - length - separator / 2 - grab / 2, y: 0, width: grab, height: bounds.height)
            divider.isVertical = true
        case .left:
            let length = clamp(toolsLength, total: bounds.width, minimum: Self.minimumToolsWidth)
            toolsView.frame = NSRect(x: 0, y: 0, width: length, height: bounds.height)
            pageView.frame = NSRect(x: length + separator, y: 0, width: max(bounds.width - length - separator, 0), height: bounds.height)
            divider.frame = NSRect(x: length + separator / 2 - grab / 2, y: 0, width: grab, height: bounds.height)
            divider.isVertical = true
        case .window:
            break
        }
        window?.invalidateCursorRects(for: divider)
    }

    /// The page keeps its minimum first; the tools get the rest down to
    /// their own minimum (and below it only if the tab is tiny).
    private func clamp(_ length: CGFloat, total: CGFloat, minimum: CGFloat) -> CGFloat {
        let maximum = max(total - Self.minimumPageLength, 0)
        return min(max(length, minimum), maximum).rounded()
    }

    private func dividerDragged(to pointInWindow: NSPoint) {
        let point = convert(pointInWindow, from: nil)
        switch dockSide {
        case .bottom: draggedLength = point.y
        case .right: draggedLength = bounds.width - point.x
        case .left: draggedLength = point.x
        case .window: return
        }
        layoutNow()
    }

    private func rememberToolsLength() {
        guard let length = draggedLength else { return }
        draggedLength = nil
        switch dockSide {
        case .bottom: DevToolsPreferences.bottomHeight = clamp(length, total: bounds.height, minimum: Self.minimumToolsHeight)
        case .right, .left: DevToolsPreferences.sideWidth = clamp(length, total: bounds.width, minimum: Self.minimumToolsWidth)
        case .window: break
        }
        layoutNow()
    }
}

/// A slim bar across the top of docked tools whose engine draws no dock
/// controls of its own: dock-side buttons and a close button, right-aligned
/// like the ones at the end of Chrome's DevTools toolbar. The buttons never
/// take focus, so clicking them leaves the keyboard where it was.
final class DevToolsPaneHeaderView: NSView {
    static let height: CGFloat = 26

    var onDockSide: ((DevToolsDockSide) -> Void)?
    var onClose: (() -> Void)?

    /// The side the pane is on, shown as the selected dock button.
    var dockSide: DevToolsDockSide = .right {
        didSet { refreshSideStates() }
    }

    private func refreshSideStates() {
        for (side, button) in sideButtons { button.state = side == dockSide ? .on : .off }
    }

    private var sideButtons: [(DevToolsDockSide, NSButton)] = []

    private static let sideItems: [(DevToolsDockSide, String, String)] = [
        (.bottom, "rectangle.bottomthird.inset.filled", "Dock to Bottom"),
        (.right, "rectangle.rightthird.inset.filled", "Dock to Right"),
        (.left, "rectangle.leftthird.inset.filled", "Dock to Left"),
        (.window, "macwindow.on.rectangle", "Undock into Separate Window"),
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let title = NSTextField(labelWithString: "DevTools")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.textColor = .secondaryLabelColor

        var buttons: [NSView] = []
        for (side, symbol, label) in Self.sideItems {
            let button = Self.iconButton(symbol: symbol, label: label, target: self, action: #selector(sideClicked(_:)))
            button.setButtonType(.pushOnPushOff)
            button.tag = sideButtons.count
            sideButtons.append((side, button))
            buttons.append(button)
        }
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.heightAnchor.constraint(equalToConstant: 14).isActive = true
        buttons.append(separator)
        buttons.append(Self.iconButton(symbol: "xmark", label: "Close DevTools", target: self, action: #selector(closeClicked(_:))))

        let controls = NSStackView(views: buttons)
        controls.spacing = 2
        controls.alignment = .centerY

        let row = NSStackView(views: [title, NSView(), controls])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 4)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
        dockSide = .right
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Developer Tools")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func iconButton(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "square", accessibilityDescription: label)!
        let button = NSButton(image: image, target: target, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = true
        button.showsBorderOnlyWhileMouseInside = true
        button.imageScaling = .scaleProportionallyDown
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return button
    }

    @objc private func sideClicked(_ sender: NSButton) {
        let side = sideButtons[sender.tag].0
        // A push-on/push-off button flips itself; the dock state decides.
        refreshSideStates()
        onDockSide?(side)
    }

    @objc private func closeClicked(_ sender: NSButton) {
        onClose?()
    }

    /// Chrome's DevTools toolbar grey, shared with the device toolbar.
    static let toolbarColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x28 / 255.0, green: 0x28 / 255.0, blue: 0x28 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0xf1 / 255.0, green: 0xf3 / 255.0, blue: 0xf4 / 255.0, alpha: 1)
    }

    /// The toolbar grey, with a hairline under it.
    override func draw(_ dirtyRect: NSRect) {
        Self.toolbarColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {}
}

/// The draggable split between page and tools: a one-point line with a
/// wider invisible grab area. Dragging uses ordinary mouseDragged events,
/// never a nested tracking loop, which would stall the main run loop the
/// CEF engine is pumped from.
private final class DevToolsDividerView: NSView {
    static let grabThickness: CGFloat = 7

    var isVertical = true {
        didSet { if isVertical != oldValue { needsDisplay = true } }
    }
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        let line = isVertical
            ? NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            : NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
        line.fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isVertical ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        onDrag?(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
}

/// `--open-devtools <what>` and `--devtools-dock <side>`: debug-only launch
/// arguments that open the first window's developer tools a few seconds
/// after launch, so docking can be checked with passive screenshots and no
/// synthetic input (AGENTS.md's UI verification protocol). <what> is
/// `default`, `console`, `elements`, `picker`, or `inspect:X,Y` (a point in
/// the page view's coordinates). No-ops unless passed.
enum DevToolsLaunchOption {
    /// `--device-toolbar responsive|<preset name>`: turns the first window's
    /// device toolbar on, the same way, and logs the resulting layout.
    private static func applyDeviceToolbarIfRequested(_ args: [String]) {
        guard let index = args.firstIndex(of: "--device-toolbar"), index + 1 < args.count else { return }
        let what = args[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let tab = NSApp.windows.lazy.compactMap({ $0.windowController as? BrowserWindowController })
                .first?.activeTab else { return }
            if let preset = ResponsiveDevicePreset.all.first(where: { $0.name == what }) {
                tab.deviceToolbar.select(preset)
            } else {
                tab.deviceToolbar.selectResponsive()
            }
            let toolbar = tab.deviceToolbar
            NSLog("Browser: --device-toolbar %@: on=%d preset=%@ %dx%d @%.1f", what, toolbar.isOn,
                  toolbar.preset?.name ?? "Responsive", toolbar.width, toolbar.height, toolbar.scale)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSLog("Browser: --device-toolbar layout: %@", tab.devTools.layoutSummary)
            }
        }
    }

    static func applyIfRequested() {
        let args = CommandLine.arguments
        applyDeviceToolbarIfRequested(args)
        guard let index = args.firstIndex(of: "--open-devtools"), index + 1 < args.count else { return }
        let what = args[index + 1]
        var side: DevToolsDockSide?
        if let sideIndex = args.firstIndex(of: "--devtools-dock"), sideIndex + 1 < args.count {
            side = DevToolsDockSide(rawValue: args[sideIndex + 1])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard let tab = NSApp.windows.lazy.compactMap({ $0.windowController as? BrowserWindowController })
                .first?.activeTab else {
                NSLog("Browser: --open-devtools found no browser window")
                return
            }
            if let side { DevToolsPreferences.dockSide = side }
            NSLog("Browser: --open-devtools %@ (dock %@)", what, DevToolsPreferences.dockSide.rawValue)
            let devTools = tab.devTools
            switch what {
            case "console": devTools.open(panel: .console)
            case "elements": devTools.open(panel: .elements)
            case "picker": devTools.startElementPicker()
            case let spec where spec.hasPrefix("inspect:"):
                let parts = spec.dropFirst("inspect:".count).split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { return }
                devTools.inspectElement(at: NSPoint(x: parts[0], y: parts[1]))
            default: devTools.open(panel: .default)
            }
            // Where everything ended up, for checking a launch from its log
            // alone when no screenshot can be taken.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSLog("Browser: --open-devtools layout: %@", devTools.layoutSummary)
            }
        }
    }
}
