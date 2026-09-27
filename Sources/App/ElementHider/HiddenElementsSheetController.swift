import AppKit

/// "Show Hidden Elements on This Site…" -- what the element hider has
/// taken off the front tab's site, and the way to put it back.
///
/// A selector is not something anyone can read, so selecting a row brings
/// that one element back on the page, outlined and scrolled into view,
/// until the selection moves or the sheet closes: you decide what to
/// restore by looking at it.
final class HiddenElementsSheetController: NSObject {
    /// Test-only launch flag: open this sheet as soon as the first real page
    /// has loaded. Agents may not drive this app's UI with synthetic input,
    /// and the sheet is otherwise only reachable from a menu.
    static let autoPresentFlag = "--show-hidden-elements"

    static let shared = HiddenElementsSheetController()

    private var sheetWindow: NSWindow?

    @discardableResult
    func present(in controller: BrowserWindowController) -> Bool {
        guard sheetWindow == nil,
              let window = controller.window,
              let tab = controller.activeTab,
              let site = ElementHiderCoordinator.site(of: tab)
        else { return false }

        let content = HiddenElementsViewController(site: site, tab: tab)
        content.onDone = { [weak self] in self?.dismiss() }
        content.onHideMore = { [weak self] in
            self?.dismiss()
            ElementHiderCoordinator.shared.startPicking(tab)
        }

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
        (sheet.contentViewController as? HiddenElementsViewController)?.endPeek()
        sheet.sheetParent?.endSheet(sheet)
        sheetWindow = nil
    }
}

private final class HiddenElementsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let contentWidth: CGFloat = 440
    private static let margin: CGFloat = 20

    private let site: String
    private weak var tab: Tab?
    private var elements: [HiddenElement] = []
    private var isPeeking = false

    var onDone: (() -> Void)?
    var onHideMore: (() -> Void)?

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "Nothing is hidden on this site.")
    private let restoreButton = NSButton()
    private let restoreAllButton = NSButton()

    init(site: String, tab: Tab) {
        self.site = site
        self.tab = tab
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var store: HiddenElementStore? {
        tab.map { HiddenElementStores.store(forProfileId: $0.profileId) }
    }

    /// The tab, only while it is still on this site: a peek written into
    /// some other site's page would show or hide the wrong things there.
    private var tabOnSite: Tab? {
        guard let tab, ElementHiderCoordinator.site(of: tab) == site else { return nil }
        return tab
    }

    override func loadView() {
        let container = NSVisualEffectView()
        container.material = .sheet
        container.blendingMode = .behindWindow
        container.state = .active

        let title = NSTextField(labelWithString: "Hidden on \(site)")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: "Select an item to show it on the page. Restoring it keeps it visible from now on.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("element"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(restoreSelected)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        ListAppearance.apply(to: tableView, in: scrollView, rowHeight: 38)

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        restoreButton.title = "Restore"
        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restoreSelected)
        restoreAllButton.title = "Restore All"
        restoreAllButton.bezelStyle = .rounded
        restoreAllButton.target = self
        restoreAllButton.action = #selector(restoreAll)
        let hideMore = NSButton(title: "Hide More…", target: self, action: #selector(hideMore))
        hideMore.bezelStyle = .rounded
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let leading = NSStackView(views: [restoreButton, restoreAllButton])
        leading.spacing = 8
        let trailing = NSStackView(views: [hideMore, done])
        trailing.spacing = 8
        for stack in [leading, trailing] {
            stack.orientation = .horizontal
            stack.translatesAutoresizingMaskIntoConstraints = false
        }

        [title, subtitle, scrollView, emptyLabel, leading, trailing].forEach(container.addSubview)

        let margin = Self.margin
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth),

            title.topAnchor.constraint(equalTo: container.topAnchor, constant: margin),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -margin),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            subtitle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),

            scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            scrollView.heightAnchor.constraint(equalToConstant: 220),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            leading.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 16),
            leading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: margin),
            leading.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -margin),

            trailing.firstBaselineAnchor.constraint(equalTo: leading.firstBaselineAnchor),
            trailing.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -margin),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: leading.trailingAnchor, constant: 12),
            done.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        view = container
        reload()
    }

    private func reload() {
        elements = store?.elements(onSite: site) ?? []
        tableView.reloadData()
        emptyLabel.isHidden = !elements.isEmpty
        restoreAllButton.isEnabled = !elements.isEmpty
        restoreButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        elements.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("HiddenElementCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HiddenElementCell ?? HiddenElementCell()
        cell.identifier = identifier
        let element = elements[row]
        cell.titleField.stringValue = element.label
        cell.detailField.stringValue = element.note.isEmpty ? element.selector : element.note
        cell.toolTip = element.selector
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        restoreButton.isEnabled = tableView.selectedRow >= 0
        let row = tableView.selectedRow
        guard row >= 0, row < elements.count else {
            endPeek()
            return
        }
        let selector = elements[row].selector
        let others = elements.map(\.selector).filter { $0 != selector }
        tabOnSite?.executeJavaScript(ElementHiderScript.peek(
            selector: selector,
            cssWithout: HiddenElementStyleSheet.css(for: others)))
        isPeeking = true
    }

    func endPeek() {
        guard isPeeking else { return }
        isPeeking = false
        tabOnSite?.executeJavaScript(ElementHiderScript.unpeek(css: HiddenElementStyleSheet.css(for: elements.map(\.selector))))
    }

    // MARK: - Actions

    @objc private func restoreSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < elements.count else { return }
        let selector = elements[row].selector
        storeChanged { $0.restore(selector: selector, onSite: site) }
    }

    @objc private func restoreAll() {
        storeChanged { $0.restoreAll(onSite: site) }
    }

    /// The selection is cleared first so the change does not land as a
    /// peek at whichever row slides into the removed one's place.
    private func storeChanged(_ change: (HiddenElementStore) -> Void) {
        guard let tab, let store else { return }
        isPeeking = false
        tableView.deselectAll(nil)
        change(store)
        reload()
        tabOnSite?.executeJavaScript(ElementHiderScript.unpeek(css: HiddenElementStyleSheet.css(for: elements.map(\.selector))))
        ElementHiderCoordinator.shared.siteStyleSheetsChanged(profileId: tab.profileId)
    }

    @objc private func hideMore() {
        onHideMore?()
    }

    @objc private func done() {
        onDone?()
    }
}

private final class HiddenElementCell: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingTail
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [titleField, detailField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
