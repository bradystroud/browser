import AppKit
import SecurityInterface

/// What the site card's rows do. Supplied by the window controller, which
/// owns every one of these actions already; the card only offers them.
struct SiteCardActions {
    let copyAddress: () -> Void
    let print: () -> Void
    /// nil when the page has no site to configure (a file, an internal page).
    let showSiteSettings: (() -> Void)?
    /// Presents the system certificate sheet on the window.
    let showCertificate: (SecTrust) -> Void
}

/// The site card: a popover from the omnibox's site button (or the page's
/// "Site Information…" context-menu item) saying how the page arrived, with
/// its zoom and the few commands that belong to the page rather than the
/// browser.
///
/// A popover is a window. Presenting one while the omnibox's field editor is
/// active crashes AppKit (see CLAUDE.md's "Never order a window on screen
/// while the omnibox has focus"), so this type never decides *when* to show:
/// BrowserWindowController.presentSiteCard resigns the omnibox first and
/// refuses if it is still editing.
final class SiteCardController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    /// The tab and address the open card describes. Once either changes the
    /// card is about a page no longer on screen -- see isStale(for:).
    private weak var shownTab: Tab?
    private var shownURL: String?

    func isStale(for activeTab: Tab) -> Bool {
        isShown && (shownTab !== activeTab || shownURL != activeTab.urlString)
    }

    func show(for tab: Tab, relativeTo anchor: NSView, actions: SiteCardActions) {
        let (security, trust) = tab.connectionSecurity()
        let content = SiteCardViewController(
            tab: tab,
            security: security,
            serverTrust: trust,
            actions: actions,
            dismiss: { [weak self] in self?.close() }
        )
        popover.contentViewController = content
        shownTab = tab
        shownURL = tab.urlString
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        shownTab = nil
        shownURL = nil
    }
}

private final class SiteCardViewController: NSViewController {
    private static let width: CGFloat = 300
    private static let margin: CGFloat = 14

    private let tab: Tab
    private let security: ConnectionSecurity
    private let serverTrust: SecTrust?
    private let actions: SiteCardActions
    private let dismiss: () -> Void
    private let zoomButton = NSButton()

    init(tab: Tab, security: ConnectionSecurity, serverTrust: SecTrust?, actions: SiteCardActions, dismiss: @escaping () -> Void) {
        self.tab = tab
        self.security = security
        self.serverTrust = serverTrust
        self.actions = actions
        self.dismiss = dismiss
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin - 4, right: Self.margin)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let host = NSTextField(labelWithString: Self.siteName(for: tab.urlString))
        host.font = .systemFont(ofSize: 13, weight: .semibold)
        host.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(host)
        stack.addArrangedSubview(securitySection())
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(zoomRow())
        stack.addArrangedSubview(separator())
        stack.setCustomSpacing(2, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(row("Copy Address", action: #selector(copyAddress)))
        stack.addArrangedSubview(row("Print…", action: #selector(printPage)))
        if actions.showSiteSettings != nil {
            stack.addArrangedSubview(row("Site Settings…", action: #selector(showSiteSettings)))
        }
        for view in stack.arrangedSubviews where view is SiteCardRowButton || view is NSBox {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.margin).isActive = true
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        // Solved before it is read: an unsolved wrapping label reports a
        // single very long line, and the popover would open clipped.
        container.layoutSubtreeIfNeeded()
        preferredContentSize = container.fittingSize
    }

    /// The host without "www.", or what the page is when it has no host.
    private static func siteName(for urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        if let host = url.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        if url.isFileURL { return url.lastPathComponent.isEmpty ? "File" : url.lastPathComponent }
        return url.scheme.map { "\($0):" } ?? urlString
    }

    private func securitySection() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: security.symbolName, accessibilityDescription: nil)
        icon.contentTintColor = security.isWarning ? .systemOrange : .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: security.title)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        let detail = NSTextField(wrappingLabelWithString: security.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = Self.width - 2 * Self.margin - 26

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        if let serverTrust {
            let certificate = NSButton(
                title: security == .certificateError ? "Show Certificate (Not Valid)…" : "Show Certificate…",
                target: self, action: #selector(showCertificate))
            certificate.bezelStyle = .inline
            certificate.controlSize = .small
            certificate.font = .systemFont(ofSize: 11)
            text.addArrangedSubview(certificate)
            text.setCustomSpacing(6, after: detail)
        }

        let section = NSStackView(views: [icon, text])
        section.orientation = .horizontal
        section.alignment = .top
        section.spacing = 8
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        return section
    }

    private func zoomRow() -> NSView {
        let label = NSTextField(labelWithString: "Zoom")
        label.font = .systemFont(ofSize: 13)

        let out = stepButton(symbol: "minus", help: "Zoom Out", action: #selector(zoomOut))
        let `in` = stepButton(symbol: "plus", help: "Zoom In", action: #selector(zoomIn))
        zoomButton.bezelStyle = .inline
        zoomButton.isBordered = false
        zoomButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        zoomButton.contentTintColor = .secondaryLabelColor
        zoomButton.target = self
        zoomButton.action = #selector(resetZoom)
        zoomButton.toolTip = "Actual Size"
        zoomButton.translatesAutoresizingMaskIntoConstraints = false
        zoomButton.widthAnchor.constraint(equalToConstant: 48).isActive = true
        refreshZoom()

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, out, zoomButton, `in`])
        row.orientation = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.margin).isActive = true
        return row
    }

    private func stepButton(symbol: String, help: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: self, action: action)
        button.bezelStyle = .toolbar
        button.showsBorderOnlyWhileMouseInside = true
        button.toolTip = help
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func row(_ title: String, action: Selector) -> SiteCardRowButton {
        let button = SiteCardRowButton(title: title, target: self, action: action)
        return button
    }

    private func refreshZoom() {
        zoomButton.title = tab.zoomPercentLabel
    }

    @objc private func zoomIn() {
        tab.zoomIn()
        refreshZoom()
    }

    @objc private func zoomOut() {
        tab.zoomOut()
        refreshZoom()
    }

    @objc private func resetZoom() {
        tab.resetZoom()
        refreshZoom()
    }

    /// The card goes first, then the command runs a turn later: a sheet or a
    /// print panel that starts while the popover is still animating out
    /// lands behind it.
    private func afterClosing(_ action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.async(execute: action)
    }

    @objc private func copyAddress() { afterClosing(actions.copyAddress) }
    @objc private func printPage() { afterClosing(actions.print) }

    @objc private func showSiteSettings() {
        guard let show = actions.showSiteSettings else { return }
        afterClosing(show)
    }

    @objc private func showCertificate() {
        guard let serverTrust else { return }
        let show = actions.showCertificate
        afterClosing { show(serverTrust) }
    }
}

/// One command line in the card, drawn the way a menu item is: plain text
/// that takes the accent colour under the pointer.
private final class SiteCardRowButton: NSButton {
    /// Where the title starts inside the highlight, as a menu item's does.
    static let textInset: CGFloat = 8

    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    convenience init(title: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        alignment = .left
        font = .systemFont(ofSize: 13)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: isHovering ? NSColor.white : NSColor.labelColor,
        ]
        let string = NSAttributedString(string: title, attributes: attributes)
        let size = string.size()
        string.draw(at: NSPoint(x: Self.textInset, y: (bounds.height - size.height) / 2))
    }
}
