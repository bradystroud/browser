import AppKit

/// Makes a non-installed build impossible to mistake for the real install:
/// an amber strip across the top of every browser window plus a "DEV" Dock
/// badge.
///
/// A build counts as a dev build when the running bundle is anywhere other
/// than exactly `/Applications/Browser.app` (symlinks resolved), or when the
/// launch carries `--profiles-root` (scratch data, even when run from
/// /Applications). `--dev-banner on|off` overrides both rules.
///
/// The real install pays for one path comparison and an argv scan, once:
/// no view is created, no inset applied, no badge set.
///
/// Build metadata comes from `BRWBuildCommit`/`BRWBuildBranch`/`BRWBuildDirty`
/// in Info.plist, written by `scripts/stamp-build-info.sh` before signing.
enum DevBuildIndicator {
    static let installedBundlePath = "/Applications/Browser.app"
    static let bannerHeight: CGFloat = 22

    static let isEnabled: Bool = {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--dev-banner"), index + 1 < args.count {
            switch args[index + 1].lowercased() {
            case "on": return true
            case "off": return false
            default: break
            }
        }
        if args.contains("--profiles-root") { return true }
        return bundlePath != installedBundlePath
    }()

    /// How far the window's chrome must start below the top of contentView.
    /// The banner lives inside contentView (not as a sibling of it), which is
    /// the only place NSGlassEffectView guarantees it a z-order.
    static var topInset: CGFloat { isEnabled ? bannerHeight : 0 }

    static func attach(to window: NSWindow) {
        guard isEnabled, let contentView = window.contentView else { return }
        NSApp.dockTile.badgeLabel = "DEV"
        let banner = DevBuildBannerView(frame: NSRect(
            x: 0, y: contentView.bounds.height - bannerHeight,
            width: contentView.bounds.width, height: bannerHeight))
        banner.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(banner)
    }

    // MARK: - Details

    fileprivate static let bundlePath: String =
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path

    fileprivate static var profilesRoot: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--profiles-root"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    fileprivate static var engineName: String {
        switch CommandLineArgs.engineChoice() {
        case .cef: return "CEF"
        case .webkit: return "WebKit"
        }
    }

    fileprivate static var buildDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let commit = info["BRWBuildCommit"] as? String ?? "unknown"
        let branch = info["BRWBuildBranch"] as? String ?? "unknown"
        let dirty = (info["BRWBuildDirty"] as? Bool ?? false) ? "+dirty" : ""
        return "\(commit) (\(branch))\(dirty)"
    }

    fileprivate static func abbreviated(_ path: String, maxLength: Int = 48) -> String {
        let short = (path as NSString).abbreviatingWithTildeInPath
        guard short.count > maxLength else { return short }
        let keep = maxLength - 1
        return "\(short.prefix(keep / 2))…\(short.suffix(keep - keep / 2))"
    }

    fileprivate static var bannerText: String {
        var parts = ["DEV BUILD", abbreviated(bundlePath), buildDescription, engineName]
        if let profilesRoot { parts.append(abbreviated(profilesRoot, maxLength: 40)) }
        return parts.joined(separator: " · ")
    }

    fileprivate static var fullText: String {
        var lines = [
            "Bundle: \(bundlePath)",
            "Build: \(buildDescription)",
            "Engine: \(engineName)",
        ]
        if let profilesRoot { lines.append("Profiles root: \(profilesRoot)") }
        return lines.joined(separator: "\n")
    }
}

private final class DevBuildBannerView: NSView {
    /// The traffic lights sit on the toolbar row below the banner (see
    /// BrowserWindow's layout), so the text starts at the plain edge inset
    /// in every mode, full screen included.
    private static let leadingInset: CGFloat = 10

    private let label = NSTextField(labelWithString: DevBuildIndicator.bannerText)
    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Fixed, not dynamic: the strip should look identical in light and
        // dark mode and never resemble any system chrome.
        layer?.backgroundColor = NSColor(srgbRed: 1.0, green: 0.64, blue: 0.0, alpha: 1).cgColor
        toolTip = DevBuildIndicator.fullText
        setAccessibilityLabel("Development build: \(DevBuildIndicator.fullText)")

        label.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = NSColor(white: 0.08, alpha: 1)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.autoresizingMask = [.width]
        addSubview(label)
        layoutLabel(inset: Self.leadingInset)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }


    private func layoutLabel(inset: CGFloat) {
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(
            x: inset, y: (bounds.height - height) / 2,
            width: max(0, bounds.width - inset - 8), height: height)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    private var mouseDownEvent: NSEvent?
    private var didDrag = false

    /// A click shows the full details; a drag still moves the window, since
    /// this strip covers part of the (hidden) titlebar's drag area. Plain
    /// event overrides rather than a nextEvent tracking loop, which would
    /// block the main run loop the engine's message pump runs on.
    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let down = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard hypot(dx, dy) > 3 else { return }
        didDrag = true
        window?.performDrag(with: down)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, !didDrag else { return }
        showDetails()
    }

    private func showDetails() {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let text = NSTextField(wrappingLabelWithString: DevBuildIndicator.fullText)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = 520
        let size = text.fittingSize
        let container = NSView(frame: NSRect(x: 0, y: 0, width: size.width + 24, height: size.height + 20))
        text.frame = NSRect(x: 12, y: 10, width: size.width, height: size.height)
        container.addSubview(text)

        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = container.frame.size
        let anchor = NSRect(x: label.frame.minX, y: 0, width: min(label.frame.width, 200), height: bounds.height)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .minY)
        self.popover = popover
    }
}
