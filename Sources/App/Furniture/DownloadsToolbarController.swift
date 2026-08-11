import AppKit

/// The toolbar downloads button and its popover (browser-8vt, Brady's ask) --
/// the Safari/Chrome affordance this app was missing: downloads already
/// worked and were already recorded (DownloadCoordinator -> DownloadStore),
/// but the only way to see one was the separate ⌘⇧J window, so a download
/// gave no visible sign it had happened at all.
///
/// One per window, owned by BrowserWindow alongside ReaderModeController and
/// attached the same way and for the same reason: it has to be observing
/// download notifications from the window's first tab onward, not only once
/// the user first acts.
///
/// The button is a floating overlay in the toolbar row rather than a real
/// toolbar item, matching how the Reader button already does it -- see
/// BrowserWindowController.toolbarRowHeight's doc comment for why that band
/// is the only safe place for one (the content area below it is covered by
/// CEF's own hosted view regardless of AppKit z-order).
///
/// Scope note: the popover lists **this session's** downloads, while the
/// ⌘⇧J window lists the profile's whole persisted history. That split is
/// deliberate -- see DownloadCoordinator.startedRowIds.
final class DownloadsToolbarController: NSObject, NSPopoverDelegate {
    /// Matches ReaderModeController.buttonSize so the two sit as a matched
    /// pair on the toolbar's trailing edge.
    private static let buttonSize: CGFloat = 18
    /// Gap between this button and the Reader button's slot to its right.
    private static let buttonGap: CGFloat = 10
    /// Reader's own trailing inset, which this button is positioned relative
    /// to. Restated rather than shared because this controller only needs to
    /// sit beside that slot, never to set it.
    private static let readerTrailingInset: CGFloat = 12

    private weak var window: BrowserWindow?
    private var buttonView: NSButton?
    private let popover = NSPopover()
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func attach(to window: BrowserWindow) {
        self.window = window
        observers.append(NotificationCenter.default.addObserver(
            forName: .downloadsDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.matchesThisWindow(notification.object) else { return }
            self.updateButtonVisibility()
            self.refreshPopoverContentIfShown()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .downloadDidStart, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, self.matchesThisWindow(notification.object) else { return }
            self.updateButtonVisibility()
            self.presentOnDownloadStart()
        })
    }

    /// Opens or closes the popover. The button's own click action; the
    /// existing ⌘⇧J menu item deliberately still opens the full history
    /// window instead, since that's the one that shows more than this
    /// session.
    func toggle() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        updateButtonVisibility(forceVisible: true)
        showPopover()
    }

    // MARK: - Notification routing

    /// Download notifications carry a profile id, and every window of that
    /// profile hears them. Only this window's own profile is relevant.
    private func matchesThisWindow(_ notificationObject: Any?) -> Bool {
        guard let profileId = notificationObject as? String,
              let controller = window?.windowController as? BrowserWindowController else { return false }
        return controller.profile.id == profileId
    }

    /// Auto-presents when a download begins -- but only in the key window.
    /// Without that check every open window of the same profile would pop its
    /// own copy for a single download, and a background window would steal
    /// attention for something the user started in a different one.
    private func presentOnDownloadStart() {
        // Not agent-verifiable, and deliberately not bent to become so: a
        // .transient popover closes as soon as its window isn't key, so under
        // --test-no-activate (which never activates the app) it would open and
        // shut in the same breath. Relaxing this guard for tests produces a
        // screenshot of nothing while weakening the real rule -- tried, and
        // reverted. The button appearing *is* verifiable, and is; the popover
        // itself needs a real click.
        guard let window, window.isKeyWindow, !popover.isShown else { return }
        showPopover()
    }

    // MARK: - Button

    /// Shown only once this session has downloads, which is Safari's own
    /// behaviour -- an always-present button that does nothing on click for
    /// most of a browsing session is just chrome noise.
    private func updateButtonVisibility(forceVisible: Bool = false) {
        let shouldShow = forceVisible || DownloadCoordinator.shared.hasSessionDownloads
        guard shouldShow else {
            buttonView?.isHidden = true
            return
        }
        ensureButton()
        buttonView?.isHidden = false
    }

    private func ensureButton() {
        guard buttonView == nil, let window, let contentView = window.contentView else { return }
        let size = Self.buttonSize
        let toolbarHeight = (window.windowController as? BrowserWindowController)?.toolbarRowHeight ?? 44
        let button = NSButton(
            image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Downloads")!,
            target: self, action: #selector(buttonTapped)
        )
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "Downloads"
        // Immediately left of the Reader button's slot. The slot is reserved
        // whether or not Reader is currently showing: Reader appears only on
        // article-like pages, and a downloads button that slid sideways every
        // time you navigated would be worse than one sitting a fixed distance
        // in from the edge.
        button.frame = NSRect(
            x: contentView.bounds.width - Self.readerTrailingInset - size - Self.buttonGap - size,
            y: contentView.bounds.height - (toolbarHeight + size) / 2,
            width: size,
            height: size
        )
        button.autoresizingMask = [.minXMargin, .minYMargin]
        contentView.addSubview(button)
        buttonView = button
    }

    @objc private func buttonTapped() {
        toggle()
    }

    // MARK: - Popover

    private func showPopover() {
        guard let anchor = buttonView, !anchor.isHidden,
              let controller = window?.windowController as? BrowserWindowController else { return }
        let content = DownloadsPopoverViewController(
            profile: controller.profile,
            onShowAll: { [weak self] in
                self?.popover.performClose(nil)
                DownloadsWindowManager.shared.show(for: controller.profile)
            }
        )
        popover.contentViewController = content
        popover.contentSize = content.preferredContentSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    /// Live progress while the popover is open -- without this a download
    /// started from the popover's own auto-present would sit at 0% until the
    /// user closed and reopened it.
    private func refreshPopoverContentIfShown() {
        guard popover.isShown,
              let content = popover.contentViewController as? DownloadsPopoverViewController else { return }
        content.reload()
        popover.contentSize = content.preferredContentSize
    }
}

/// The popover's contents: this session's downloads, newest first, each row
/// clickable to open the file and with its own Reveal-in-Finder button.
private final class DownloadsPopoverViewController: NSViewController {
    private static let width: CGFloat = 360
    private static let rowHeight: CGFloat = 48
    private static let headerHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 32
    private static let maxVisibleRows = 6

    private let profile: Profile
    private let onShowAll: () -> Void
    private let stackView = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "No downloads yet.")
    private var downloads: [DownloadItem] = []

    init(profile: Profile, onShowAll: @escaping () -> Void) {
        self.profile = profile
        self.onShowAll = onShowAll
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        setUpViews()
        reload()
    }

    private func setUpViews() {
        let header = NSTextField(labelWithString: "Downloads")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.frame = NSRect(x: 14, y: 0, width: 200, height: 18)
        header.autoresizingMask = [.minYMargin]
        view.addSubview(header)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        view.addSubview(emptyLabel)

        stackView.orientation = .vertical
        stackView.spacing = 0
        stackView.alignment = .leading
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = stackView
        view.addSubview(scrollView)

        let showAll = NSButton(title: "Show All Downloads", target: self, action: #selector(showAllTapped))
        showAll.bezelStyle = .inline
        showAll.controlSize = .small
        showAll.frame = NSRect(x: 10, y: 8, width: 160, height: 20)
        showAll.autoresizingMask = [.maxYMargin]
        view.addSubview(showAll)

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearTapped))
        clear.bezelStyle = .inline
        clear.controlSize = .small
        clear.frame = NSRect(x: Self.width - 70, y: 8, width: 60, height: 20)
        clear.autoresizingMask = [.minXMargin, .maxYMargin]
        view.addSubview(clear)
    }

    /// Only this session's rows -- see DownloadCoordinator.isFromThisSession.
    func reload() {
        let all = (try? ProfileDataStoreManager.shared.stores(for: profile).downloads.all()) ?? []
        downloads = all.filter { DownloadCoordinator.shared.isFromThisSession(rowId: $0.id) }

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for download in downloads {
            stackView.addArrangedSubview(DownloadRowView(download: download, width: Self.width))
        }
        emptyLabel.isHidden = !downloads.isEmpty
        scrollView.isHidden = downloads.isEmpty
        layoutContents()
    }

    override var preferredContentSize: NSSize {
        get {
            let rows = min(max(downloads.count, 1), Self.maxVisibleRows)
            let body = downloads.isEmpty ? 44 : CGFloat(rows) * Self.rowHeight
            return NSSize(width: Self.width, height: Self.headerHeight + body + Self.footerHeight)
        }
        set { super.preferredContentSize = newValue }
    }

    private func layoutContents() {
        let size = preferredContentSize
        view.frame = NSRect(origin: .zero, size: size)
        // Top-down: header, list, footer buttons.
        if let header = view.subviews.first as? NSTextField {
            header.frame = NSRect(x: 14, y: size.height - 22, width: size.width - 28, height: 18)
        }
        let listY = Self.footerHeight
        let listHeight = size.height - Self.headerHeight - Self.footerHeight
        scrollView.frame = NSRect(x: 0, y: listY, width: size.width, height: listHeight)
        stackView.frame = NSRect(
            x: 0, y: 0, width: size.width,
            height: max(listHeight, CGFloat(downloads.count) * Self.rowHeight)
        )
        emptyLabel.frame = NSRect(x: 0, y: listY + listHeight / 2 - 9, width: size.width, height: 18)
    }

    @objc private func showAllTapped() {
        onShowAll()
    }

    /// Clears the *session* list only -- completed rows leave the store, so
    /// this matches what the popover shows rather than silently wiping the
    /// profile's whole download history behind the ⌘⇧J window.
    @objc private func clearTapped() {
        try? ProfileDataStoreManager.shared.stores(for: profile).downloads.clearCompleted()
        NotificationCenter.default.post(name: .downloadsDidChange, object: profile.id)
        reload()
    }
}

/// One download: icon, file name, status/progress, Reveal in Finder.
private final class DownloadRowView: NSView {
    private let download: DownloadItem
    private let nameLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let iconView = NSImageView()
    private let revealButton = NSButton()

    init(download: DownloadItem, width: CGFloat) {
        self.download = download
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 48))
        setUpViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 48) }

    private func setUpViews() {
        // The real Finder icon for the file's type, so a row reads at a
        // glance the way it does in Safari's list.
        iconView.image = NSWorkspace.shared.icon(forFile: download.destinationPath)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.frame = NSRect(x: 12, y: 10, width: 28, height: 28)
        addSubview(iconView)

        nameLabel.stringValue = download.suggestedName
        nameLabel.font = .systemFont(ofSize: 12)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.frame = NSRect(x: 50, y: 26, width: bounds.width - 50 - 44, height: 16)
        addSubview(nameLabel)

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 50, y: 8, width: bounds.width - 50 - 44, height: 14)
        addSubview(statusLabel)

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.controlSize = .small
        progressIndicator.frame = NSRect(x: 50, y: 10, width: bounds.width - 50 - 44, height: 8)
        addSubview(progressIndicator)

        revealButton.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Reveal in Finder")
        revealButton.isBordered = false
        revealButton.contentTintColor = .secondaryLabelColor
        revealButton.toolTip = "Reveal in Finder"
        revealButton.target = self
        revealButton.action = #selector(reveal)
        revealButton.frame = NSRect(x: bounds.width - 34, y: 15, width: 18, height: 18)
        addSubview(revealButton)

        applyState()
    }

    private func applyState() {
        switch download.state {
        case .pending, .inProgress:
            progressIndicator.isHidden = false
            statusLabel.isHidden = true
            if download.totalBytes > 0 {
                progressIndicator.isIndeterminate = false
                progressIndicator.doubleValue = Double(download.receivedBytes) / Double(download.totalBytes) * 100
            } else {
                // No Content-Length: a determinate bar stuck at 0 would read
                // as "not started" rather than "size unknown".
                progressIndicator.isIndeterminate = true
                progressIndicator.startAnimation(nil)
            }
        case .completed:
            progressIndicator.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = Self.byteFormatter.string(fromByteCount: max(download.receivedBytes, 0))
        case .cancelled:
            progressIndicator.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = "Cancelled"
        case .failed, .interrupted:
            progressIndicator.isHidden = true
            statusLabel.isHidden = false
            statusLabel.stringValue = "Failed"
        }
    }

    /// Click anywhere on the row to open the file, matching Safari. Only for
    /// a completed download -- opening a half-written file is at best useless
    /// and at worst hands a truncated file to whatever app claims its type.
    override func mouseDown(with event: NSEvent) {
        guard download.state == .completed else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: download.destinationPath))
    }

    @objc private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: download.destinationPath)])
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}
