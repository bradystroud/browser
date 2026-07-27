import AppKit

private final class DownloadStatusView: NSView {
    let label = NSTextField(labelWithString: "")
    let progressIndicator = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.isIndeterminate = false
        addSubview(progressIndicator)
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        progressIndicator.frame = NSRect(x: 4, y: bounds.height - 18, width: bounds.width - 8, height: 12)
        label.frame = NSRect(x: 4, y: 4, width: bounds.width - 8, height: 14)
    }
}

/// ⌘⇧J -- per-profile downloads list with progress bars, driven by
/// DownloadStore and refreshed live via DownloadCoordinator's
/// .downloadsDidChange notification (posted from CefDownloadHandler
/// callbacks, see BRWClientHandler.mm's OnBeforeDownload/OnDownloadUpdated).
final class DownloadsWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let profile: Profile
    private let tableView = NSTableView()
    private var downloads: [DownloadItem] = []
    private var changeObserver: NSObjectProtocol?

    init(profile: Profile) {
        self.profile = profile
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Downloads — \(profile.name)"
        window.center()
        super.init(window: window)
        window.delegate = self
        setUpViews()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .downloadsDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as? String == self.profile.id else { return }
            self.reload()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    func show() {
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setUpViews() {
        guard let contentView = window?.contentView else { return }
        let margin: CGFloat = 12
        let buttonRowHeight: CGFloat = 28

        let revealButton = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealSelected))
        revealButton.frame = NSRect(x: margin, y: margin, width: 140, height: buttonRowHeight)
        revealButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(revealButton)

        let clearButton = NSButton(title: "Clear Completed", target: self, action: #selector(clearCompleted))
        clearButton.frame = NSRect(x: contentView.bounds.width - margin - 140, y: margin, width: 140, height: buttonRowHeight)
        clearButton.autoresizingMask = [.minXMargin, .maxYMargin]
        contentView.addSubview(clearButton)

        let scrollY = margin + buttonRowHeight + 8
        let scrollView = NSScrollView(frame: NSRect(
            x: margin,
            y: scrollY,
            width: contentView.bounds.width - margin * 2,
            height: contentView.bounds.height - scrollY - margin
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let nameColumn = NSTableColumn(identifier: .init("name"))
        nameColumn.title = "Name"
        nameColumn.width = 280
        let statusColumn = NSTableColumn(identifier: .init("status"))
        statusColumn.title = "Status"
        statusColumn.width = 220

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(statusColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 40
        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
    }

    private func reload() {
        downloads = (try? ProfileDataStoreManager.shared.stores(for: profile).downloads.all()) ?? []
        tableView.reloadData()
    }

    @objc private func revealSelected() {
        let index = tableView.selectedRow
        guard downloads.indices.contains(index) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: downloads[index].destinationPath)])
    }

    @objc private func clearCompleted() {
        try? ProfileDataStoreManager.shared.stores(for: profile).downloads.clearCompleted()
        reload()
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        downloads.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard downloads.indices.contains(row) else { return nil }
        let download = downloads[row]
        switch tableColumn?.identifier.rawValue {
        case "name":
            let identifier = NSUserInterfaceItemIdentifier("nameCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
                ?? NSTextField(labelWithString: "")
            cell.identifier = identifier
            cell.stringValue = download.suggestedName
            cell.lineBreakMode = .byTruncatingMiddle
            return cell
        case "status":
            return statusView(for: download)
        default:
            return nil
        }
    }

    private func statusView(for download: DownloadItem) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier("statusCell")
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? DownloadStatusView
            ?? DownloadStatusView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        view.identifier = identifier

        switch download.state {
        case .pending, .inProgress:
            view.progressIndicator.isHidden = false
            if download.totalBytes > 0 {
                view.progressIndicator.doubleValue = Double(download.receivedBytes) / Double(download.totalBytes) * 100
                view.label.stringValue = "\(Self.byteFormatter.string(fromByteCount: download.receivedBytes)) of \(Self.byteFormatter.string(fromByteCount: download.totalBytes))"
            } else {
                view.progressIndicator.doubleValue = 0
                view.label.stringValue = Self.byteFormatter.string(fromByteCount: download.receivedBytes)
            }
        case .completed:
            view.progressIndicator.isHidden = true
            view.label.stringValue = "Completed"
        case .cancelled:
            view.progressIndicator.isHidden = true
            view.label.stringValue = "Cancelled"
        case .failed, .interrupted:
            view.progressIndicator.isHidden = true
            view.label.stringValue = "Failed"
        }
        return view
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Nothing to tear down -- DownloadsWindowManager keeps this
        // controller alive (per profile) across show/hide cycles.
    }
}

final class DownloadsWindowManager {
    static let shared = DownloadsWindowManager()
    private var controllers: [String: DownloadsWindowController] = [:]

    private init() {}

    func show(for profile: Profile) {
        let controller = controllers[profile.id] ?? {
            let created = DownloadsWindowController(profile: profile)
            controllers[profile.id] = created
            return created
        }()
        controller.show()
    }
}
