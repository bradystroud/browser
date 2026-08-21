import AppKit

/// "Settings for This Website" (browser-06d) -- Safari's single per-site
/// sheet: everything that applies to the site in the front tab, in one
/// place, instead of a zoom shortcut, a shield popover and a Settings pane
/// that never mention each other.
///
/// This owns no state. Every row reads and writes the store that already
/// owns that setting:
///
/// - Page zoom -> the engine itself. CEF's HostZoomMap is keyed per host per
///   request context and persists into the profile's cache_path, so setting
///   it here is the same write ⌘+ makes (see Tab.zoomFactor).
/// - Camera / Microphone / Location / Notifications -> PermissionStore, the
///   same per-origin records the permission prompt writes.
/// - Content blocker -> BlockingSettings.allowlistedHosts through
///   ContentBlockerCoordinator, the one path the Privacy pane and the shield
///   popover also persist through.
/// - Auto-mute -> SiteSettingsStore, the only genuinely new state here, and
///   enforced by SiteSettingsEnforcer rather than merely remembered.
///
/// What is deliberately *not* here: pop-up windows, an auto-play policy,
/// screen sharing, and "use Reader automatically". Each of those is a real
/// Safari row with no mechanism behind it in this app -- Alloy-style CEF
/// exposes no per-site pop-up or autoplay setting, EnginePermissionKind has
/// no screen-share kind, and Reader is a per-invocation DOM transformation
/// with no per-site state. A switch that persists a choice nothing enforces
/// is worse than an absent row, so they are absent.
final class SiteSettingsSheetController: NSObject, NSMenuItemValidation, TabLifecycleObserver {
    /// Test-only launch flag: open this sheet by itself as soon as the first
    /// page has loaded. It exists because agents working on this app are not
    /// allowed to drive its UI with synthetic clicks (see AGENTS.md's UI
    /// verification protocol) and this sheet is otherwise only reachable from
    /// a menu -- without the flag, nobody but Brady can ever see it on
    /// screen, which is a poor way to iterate on how it looks.
    private static let autoPresentFlag = "--show-site-settings"

    static let shared = SiteSettingsSheetController()

    private var sheetWindow: NSWindow?
    private var hasAutoPresented = false

    private override init() {
        super.init()
    }

    /// Called once at launch from SiteSettingsEnforcer, which is already the
    /// thing AppDelegate touches to get this feature's observers registered.
    func registerAutoPresentIfRequested() {
        guard CommandLine.arguments.contains(Self.autoPresentFlag) else { return }
        TabLifecycleCenter.shared.addObserver(self)
    }

    func tabLifecycleEvent(_ event: TabLifecycleEvent, tab: Tab, in controller: BrowserWindowController) {
        guard case .finishedLoading = event, !hasAutoPresented, tab === controller.activeTab else { return }
        // Only counts as done once the sheet is actually up: the first page
        // to finish loading is often the start page, which has no host to
        // configure and so presents nothing.
        hasAutoPresented = present(in: controller)
    }

    /// Menu entry point. Set as the menu item's explicit target so the item
    /// needs no @objc action on any window or controller class.
    @objc func showFromMenu(_ sender: Any?) {
        guard let controller = WindowManager.shared.keyBrowserWindowController else { return }
        present(in: controller)
    }

    /// Greyed out when the front tab has no site to configure -- the start
    /// page, a data: URL, a settings tab.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let tab = WindowManager.shared.keyBrowserWindowController?.activeTab else { return false }
        return SiteIdentity.host(forURLString: tab.urlString) != nil
    }

    /// Returns false when there was nothing to show -- no window, no tab, or
    /// a page with no host (the start page, a data: URL, a settings tab).
    @discardableResult
    func present(in controller: BrowserWindowController) -> Bool {
        guard sheetWindow == nil,
              let window = controller.window,
              let tab = controller.activeTab,
              let host = SiteIdentity.host(forURLString: tab.urlString),
              let origin = SiteIdentity.origin(forURLString: tab.urlString)
        else { return false }

        let content = SiteSettingsViewController(
            host: host,
            origin: origin,
            tab: tab,
            profile: controller.profile,
            isPrivate: controller.isPrivate
        )
        content.onDone = { [weak self] in self?.dismiss() }

        let sheet = NSWindow(contentViewController: content)
        sheet.styleMask = [.titled, .fullSizeContentView]
        sheetWindow = sheet
        window.beginSheet(sheet) { [weak self] _ in
            self?.sheetWindow = nil
        }
        return true
    }

    private func dismiss() {
        guard let sheet = sheetWindow else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheetWindow = nil
    }
}

/// The sheet's contents. Split from the controller above so the controller
/// stays a two-method entry point, and so every store read happens in one
/// `refresh()` that both the initial load and every write path run through
/// -- the popups can then never show a value that was not read back from the
/// store that just took it.
private final class SiteSettingsViewController: NSViewController {
    /// One permission row. `storageKey` is PermissionStore's own raw kind
    /// string (documented on PermissionDecisionEntry) -- the Privacy pane
    /// maps the same four strings to the same four labels, and both must
    /// keep matching PermissionStore.keys(for:).
    private struct PermissionSpec {
        let title: String
        let kind: EnginePermissionKind
        let storageKey: String
    }

    private static let permissionSpecs: [PermissionSpec] = [
        PermissionSpec(title: "Camera", kind: .camera, storageKey: "camera"),
        PermissionSpec(title: "Microphone", kind: .microphone, storageKey: "microphone"),
        PermissionSpec(title: "Location", kind: .geolocation, storageKey: "geolocation"),
        PermissionSpec(title: "Notifications", kind: .notifications, storageKey: "notifications"),
    ]

    private static let contentWidth: CGFloat = 460
    private static let margin: CGFloat = 22
    private static let columnSpacing: CGFloat = 14
    private static let labelFont = NSFont.systemFont(ofSize: 13)

    /// Every popup is this wide, so the second column reads as one straight
    /// edge rather than a ragged one -- the values are short and unrelated
    /// ("125%", "Deny"), so nothing else would line them up. Derived from the
    /// widest row label rather than guessed at, so the column ends exactly on
    /// the sheet's right margin whatever the labels say and at whatever size
    /// the system font renders them.
    private static var popupWidth: CGFloat {
        let titles = ["Page Zoom", "Sound", "Content Blocker"] + permissionSpecs.map(\.title)
        let widest = titles
            .map { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }
            .max() ?? 0
        return contentWidth - margin * 2 - columnSpacing - widest.rounded(.up)
    }

    private let host: String
    private let origin: String
    private weak var tab: Tab?
    private let profile: Profile
    private let isPrivate: Bool

    var onDone: (() -> Void)?

    private let zoomPopup = NSPopUpButton()
    private let soundPopup = NSPopUpButton()
    private let blockerPopup = NSPopUpButton()
    private var permissionPopups: [NSPopUpButton] = []
    private let footnote = NSTextField(wrappingLabelWithString: "")

    init(host: String, origin: String, tab: Tab, profile: Profile, isPrivate: Bool) {
        self.host = host
        self.origin = origin
        self.tab = tab
        self.profile = profile
        self.isPrivate = isPrivate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Stores

    /// nil in a private window -- not "read but don't write", but no store
    /// access at all, matching how BrowserWindowController answers a private
    /// tab's permission request (see its tab(_:didRequestPermission:...)).
    private var permissionStore: PermissionStore? {
        isPrivate ? nil : PermissionStoreManager.shared.store(for: profile)
    }

    private var siteSettingsStore: SiteSettingsStore? {
        isPrivate ? nil : SiteSettingsStoreManager.shared.store(for: profile)
    }

    private var blockingSettings: BlockingSettings {
        ContentBlockerCoordinator.shared.settings(forProfileId: profile.id)
    }

    // MARK: - Layout

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .sheet
        container.blendingMode = .behindWindow
        container.state = .active

        let margin = Self.margin
        let icon = NSImageView()
        icon.image = tab?.faviconImage ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: host)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle

        let dot = ProfileDotView(colorHex: profile.colorHex)
        dot.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: isPrivate ? "Private Browsing" : profile.name)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let subtitleRow = NSStackView(views: [dot, subtitle])
        subtitleRow.orientation = .horizontal
        subtitleRow.spacing = 5
        subtitleRow.alignment = .centerY

        let headerText = NSStackView(views: [title, subtitleRow])
        headerText.orientation = .vertical
        headerText.alignment = .leading
        headerText.spacing = 2

        let header = NSStackView(views: [icon, headerText])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        let grid = buildGrid()
        grid.translatesAutoresizingMaskIntoConstraints = false

        footnote.font = .systemFont(ofSize: 11)
        footnote.textColor = .secondaryLabelColor
        footnote.translatesAutoresizingMaskIntoConstraints = false
        footnote.setContentCompressionResistancePriority(.required, for: .vertical)

        let restore = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restore.bezelStyle = .rounded
        restore.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(header)
        container.addSubview(separator)
        container.addSubview(grid)
        container.addSubview(footnote)
        container.addSubview(restore)
        container.addSubview(done)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            container.widthAnchor.constraint(equalToConstant: Self.contentWidth),

            header.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            header.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            grid.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),

            footnote.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16),
            footnote.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            footnote.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            restore.topAnchor.constraint(equalTo: footnote.bottomAnchor, constant: 18),
            restore.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            restore.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),

            done.firstBaselineAnchor.constraint(equalTo: restore.firstBaselineAnchor),
            done.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            done.leadingAnchor.constraint(greaterThanOrEqualTo: restore.trailingAnchor, constant: 12),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refresh()
    }

    private func buildGrid() -> NSGridView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = Self.columnSpacing
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        configure(zoomPopup, action: #selector(zoomChanged), titles: Self.zoomTitles)
        configure(soundPopup, action: #selector(soundChanged), titles: ["Allow sound", "Always mute"])
        configure(blockerPopup, action: #selector(blockerChanged), titles: ["Block ads & trackers", "Allow ads & trackers"])
        addSectionHeader("Page", to: grid, isFirst: true)
        grid.addRow(with: [rowLabel("Page Zoom"), zoomPopup])
        grid.addRow(with: [rowLabel("Sound"), soundPopup])
        grid.addRow(with: [rowLabel("Content Blocker"), blockerPopup])

        addSectionHeader("Permissions", to: grid)

        permissionPopups = Self.permissionSpecs.enumerated().map { index, spec in
            let popup = NSPopUpButton()
            configure(popup, action: #selector(permissionChanged), titles: ["Ask", "Allow", "Deny"])
            popup.tag = index
            grid.addRow(with: [rowLabel(spec.title), popup])
            return popup
        }
        return grid
    }

    private func configure(_ popup: NSPopUpButton, action: Selector, titles: [String]) {
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.widthAnchor.constraint(equalToConstant: Self.popupWidth).isActive = true
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Self.labelFont
        label.textColor = .labelColor
        return label
    }

    private func addSectionHeader(_ text: String, to grid: NSGridView, isFirst: Bool = false) {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        let row = grid.addRow(with: [label, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        // Extra air above a header that follows a group of rows; none above
        // the first, which already has the header separator above it.
        row.topPadding = isFirst ? 0 : 10
        grid.cell(atColumnIndex: 0, rowIndex: grid.numberOfRows - 1).xPlacement = .leading
    }

    private static var zoomTitles: [String] {
        PageZoom.steps.map { PageZoom.percentLabel(for: $0) }
    }

    // MARK: - Reading the stores

    /// Re-reads every store and pushes the result into the controls. The
    /// only place any popup's selection or enabled state is set, so a write
    /// that silently did not land shows up here as the control snapping back
    /// rather than as a UI that disagrees with the file on disk.
    private func refresh() {
        refreshZoom()

        soundPopup.selectItem(at: (siteSettingsStore?.record(for: host).autoMute ?? false) ? 1 : 0)
        soundPopup.isEnabled = !isPrivate

        let blocking = blockingSettings
        blockerPopup.selectItem(at: blocking.allowlistedHosts.contains(host) ? 1 : 0)
        // Disabled for a private window (nothing may be written) and when
        // the profile's content blocker is off for every site -- in that
        // case this row has no per-site meaning to offer, and the footnote
        // says where to turn it back on.
        blockerPopup.isEnabled = !isPrivate && blocking.isEnabled

        let decisions = permissionStore?.allDecisions() ?? []
        for (index, spec) in Self.permissionSpecs.enumerated() {
            let popup = permissionPopups[index]
            switch decision(for: spec, in: decisions) {
            case .none: popup.selectItem(at: 0)
            case .some(true): popup.selectItem(at: 1)
            case .some(false): popup.selectItem(at: 2)
            }
            popup.isEnabled = !isPrivate
        }

        footnote.stringValue = footnoteText(blockingEnabled: blocking.isEnabled)
    }

    private func refreshZoom() {
        let factor = tab?.zoomFactor ?? PageZoom.defaultFactor
        zoomPopup.removeAllItems()
        zoomPopup.addItems(withTitles: Self.zoomTitles)
        if let index = PageZoom.steps.firstIndex(where: { abs($0 - factor) < 0.001 }) {
            zoomPopup.selectItem(at: index)
        } else {
            // A pinch-zoom lands between the ladder's rungs. Showing the
            // nearest rung instead would be reporting a zoom the page is not
            // actually at, so the real value is added as its own item and
            // disappears again the moment a rung is chosen.
            zoomPopup.insertItem(withTitle: PageZoom.percentLabel(for: factor), at: 0)
            zoomPopup.selectItem(at: 0)
        }
        zoomPopup.isEnabled = tab != nil
    }

    /// This host's remembered answer for one permission kind. Prefers the
    /// exact origin of the page in the tab; falls back to any other stored
    /// origin on the same host (http vs https, or a non-default port) when
    /// they all agree, since the sheet is scoped to a site rather than to a
    /// security origin. Disagreement reads as "Ask" rather than as a guess
    /// about which origin the user meant.
    private func decision(for spec: PermissionSpec, in decisions: [PermissionDecisionEntry]) -> Bool? {
        let sameKind = decisions.filter { $0.kind == spec.storageKey }
        if let exact = sameKind.first(where: { $0.origin == origin }) {
            return exact.allowed
        }
        let sameHost = sameKind.filter { SiteIdentity.host(forURLString: $0.origin) == host }
        guard let first = sameHost.first, sameHost.allSatisfy({ $0.allowed == first.allowed }) else { return nil }
        return first.allowed
    }

    /// Every stored origin on this host, plus the page's own origin. A write
    /// from this sheet applies to all of them: the user answered a question
    /// about "this website", so leaving an old http:// grant in place to
    /// keep quietly applying would be the surprising behaviour.
    private func originsForHost() -> [String] {
        var origins = Set([origin])
        for entry in permissionStore?.allDecisions() ?? [] where SiteIdentity.host(forURLString: entry.origin) == host {
            origins.insert(entry.origin)
        }
        return origins.sorted()
    }

    private func footnoteText(blockingEnabled: Bool) -> String {
        // A private window's profile is a throwaway one (see
        // WindowManager.openNewPrivateWindow), so naming it in the second
        // line would be naming something the user has never seen.
        guard !isPrivate else {
            return "Private Browsing: nothing is saved for this site. Page zoom applies to this window only."
        }
        var notes: [String] = []
        if !blockingEnabled {
            notes.append("The content blocker is off for every site in this profile. Turn it on in Settings ▸ Privacy.")
        }
        notes.append("These settings apply to \(host) in the \u{201C}\(profile.name)\u{201D} profile.")
        return notes.joined(separator: "\n")
    }

    // MARK: - Writing the stores

    @objc private func zoomChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem,
              let index = Self.zoomTitles.firstIndex(of: title)
        else { return }
        tab?.setZoomFactor(PageZoom.steps[index])
        refresh()
    }

    @objc private func soundChanged(_ sender: NSPopUpButton) {
        guard let store = siteSettingsStore else { return }
        store.setAutoMute(sender.indexOfSelectedItem == 1, for: host)
        // Takes effect on the page behind the sheet immediately, not at the
        // next navigation.
        SiteSettingsEnforcer.shared.applySettingsChanged(host: host, profileId: profile.id)
        refresh()
    }

    @objc private func blockerChanged(_ sender: NSPopUpButton) {
        guard !isPrivate else { return }
        var settings = blockingSettings
        if sender.indexOfSelectedItem == 1 {
            if !settings.allowlistedHosts.contains(host) {
                settings.allowlistedHosts.append(host)
            }
        } else {
            settings.allowlistedHosts.removeAll { $0 == host }
        }
        ContentBlockerCoordinator.shared.updateSettings(settings, forProfileId: profile.id)
        refresh()
    }

    @objc private func permissionChanged(_ sender: NSPopUpButton) {
        guard let store = permissionStore,
              Self.permissionSpecs.indices.contains(sender.tag)
        else { return }
        let spec = Self.permissionSpecs[sender.tag]
        for target in originsForHost() {
            switch sender.indexOfSelectedItem {
            case 1: store.setDecision(true, for: target, kinds: spec.kind)
            case 2: store.setDecision(false, for: target, kinds: spec.kind)
            default: store.removeDecision(origin: target, kind: spec.storageKey)
            }
        }
        refresh()
    }

    @objc private func restoreDefaults(_ sender: Any?) {
        tab?.setZoomFactor(PageZoom.defaultFactor)
        if let store = permissionStore {
            for target in originsForHost() {
                for spec in Self.permissionSpecs {
                    store.removeDecision(origin: target, kind: spec.storageKey)
                }
            }
        }
        siteSettingsStore?.clear(host: host)
        SiteSettingsEnforcer.shared.applySettingsChanged(host: host, profileId: profile.id)
        if !isPrivate {
            var settings = blockingSettings
            settings.allowlistedHosts.removeAll { $0 == host }
            ContentBlockerCoordinator.shared.updateSettings(settings, forProfileId: profile.id)
        }
        refresh()
    }

    @objc private func done(_ sender: Any?) {
        onDone?()
    }

    override func cancelOperation(_ sender: Any?) {
        onDone?()
    }
}
