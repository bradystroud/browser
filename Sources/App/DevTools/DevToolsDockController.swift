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
    private let pageView: NSView
    private let divider = DevToolsDividerView()

    /// Minimum sizes, so neither side can be dragged away entirely.
    private static let minimumToolsHeight: CGFloat = 120
    private static let minimumToolsWidth: CGFloat = 260
    private static let minimumPageLength: CGFloat = 160

    var dockSide: DevToolsDockSide = .right {
        didSet { if dockSide != oldValue { layoutNow() } }
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
        addSubview(divider)
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

    func layoutNow() {
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
    static func applyIfRequested() {
        let args = CommandLine.arguments
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
        }
    }
}
