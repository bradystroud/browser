import AppKit
import UniformTypeIdentifiers

/// The welcome window a fresh install opens with, and File > Import Browser
/// Data…: a welcome page, one page that offers every import this app has
/// (each Safari and Chromium-family profile on this Mac, a bookmarks HTML
/// file, a passwords CSV), and a summary that also offers to make this the
/// default browser.
///
/// The import steps are the ones the File menu's own import windows run
/// (`SafariImportWindowController.importProfile`, the static steps on
/// `ChromiumImportWindowController`), so both paths stay one copy of the
/// logic. Like them it imports on the main thread, but one source per
/// run-loop turn, so the progress page paints between sources and the
/// engine's message pump keeps running.
///
/// SECURITY: nothing is read from the keychain until Import is pressed, and
/// the page says beforehand that macOS will ask. Each browser's key is read
/// once per import and wiped when the import ends. Parsed CSV passwords are
/// dropped when the import ends or the window closes.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    /// Shown in place of the first browser window on a brand-new install.
    /// Never for a scratch `--profiles-root` unless `--show-onboarding`
    /// asks: every agent launch there is a fresh install, and they expect a
    /// browser window.
    static func shouldShowAtLaunch(coldLaunchWasRouted: Bool) -> Bool {
        if CommandLineArgs.showOnboarding() { return true }
        return ProfileManager.shared.isFreshInstall
            && ProfilesRootResolver.explicitOverride(arguments: CommandLine.arguments) == nil
            && !coldLaunchWasRouted
            && !CommandLineArgs.hasExplicitProfileOrURLOverride()
    }

    private enum Destination: Equatable {
        case existing(profileId: String)
        case newProfile
    }

    private struct Row {
        var source: OnboardingImportSource
        var isSelected: Bool
        var destination: Destination
    }

    private struct Outcome {
        let title: String
        let icon: NSImage
        let lines: [String]
    }

    private static let windowSize = NSSize(width: 680, height: 640)
    private static let contentWidth: CGFloat = 540

    private var rows: [Row] = []
    private var safariScan: SafariImportScanner.Result?
    /// Safari is installed but its files could not be read, which is what
    /// a missing Full Disk Access grant looks like.
    private var safariNeedsAccess = false
    /// Snapshotted when the import page is built, so every destination
    /// popup lists the same profiles for the length of one import.
    private var existingProfiles: [Profile] = []
    private var outcomes: [Outcome] = []
    private var opensBrowserWindowOnClose = false
    /// False when File > Import Browser Data… opened the window, so "Not
    /// Now" closes it rather than showing the summary.
    private var startedAtWelcome = false
    private var isImporting = false

    private let pageContainer = NSView()
    private var currentPage: NSView?

    private let rowsStack = NSStackView()
    private let importButton = NSButton(title: "Import", target: nil, action: nil)
    private let passwordsCheckbox = NSButton(checkboxWithTitle: "Import saved passwords", target: nil, action: nil)
    private let passwordsNote = NSTextField(wrappingLabelWithString: "")
    private let progressLabel = NSTextField(labelWithString: "")
    private var defaultBrowserSection: NSView?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Welcome to \(Self.appName)"
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        window.contentView = background

        pageContainer.wantsLayer = true
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(pageContainer)
        NSLayoutConstraint.activate([
            pageContainer.topAnchor.constraint(equalTo: background.topAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: background.trailingAnchor),
        ])

        super.init(window: window)
        window.delegate = self
        importButton.target = self
        importButton.action = #selector(performImport(_:))
        Self.stylePrimary(importButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Browser"
    }

    // MARK: - Entry points

    /// Launch on a fresh install: starts at the welcome page.
    enum StartPage: String {
        case welcome, `import`, done
    }

    func showWelcome(opensBrowserWindowOnClose: Bool, startingAt startPage: StartPage = .welcome) {
        self.opensBrowserWindowOnClose = opensBrowserWindowOnClose
        startedAtWelcome = true
        window?.title = "Welcome to \(Self.appName)"
        switch startPage {
        case .welcome: present(makeWelcomePage(), animated: false)
        case .import: present(makeImportPage(), animated: false)
        case .done: present(makeDonePage(), animated: false)
        }
        presentWindow()
    }

    /// File > Import Browser Data…: starts at the import page.
    @objc func showImport(_ sender: Any?) {
        if window?.isVisible == true, !isImporting {
            window?.makeKeyAndOrderFront(nil)
            AppActivation.activate()
            return
        }
        guard !isImporting else { return }
        opensBrowserWindowOnClose = false
        startedAtWelcome = false
        window?.title = "Import Browser Data"
        present(makeImportPage(), animated: false)
        presentWindow()
    }

    private func presentWindow() {
        // Ordering a window on screen while the omnibox has focus can take
        // the app down (see CLAUDE.md).
        if let keyWindow = NSApp.keyWindow, keyWindow !== window {
            ExtensionsCoordinator.resignFieldEditor(in: keyWindow)
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        AppActivation.activate()
    }

    // MARK: - Paging

    private func present(_ page: NSView, animated: Bool) {
        if animated, let layer = pageContainer.layer {
            let transition = CATransition()
            transition.type = .push
            transition.subtype = .fromRight
            transition.duration = 0.35
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(transition, forKey: "page")
        }
        currentPage?.removeFromSuperview()
        page.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor),
        ])
        currentPage = page
        window?.recalculateKeyViewLoop()
    }

    /// A page is a centered column of content and a button bar along the
    /// bottom edge.
    private func makePage(content: [NSView], trailingButtons: [NSButton], leadingButtons: [NSButton] = []) -> NSView {
        let page = NSView()

        let column = NSStackView(views: content)
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(column)

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 12
        for button in leadingButtons { bar.addView(button, in: .leading) }
        for button in trailingButtons { bar.addView(button, in: .trailing) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(bar)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: page.topAnchor, constant: 56),
            column.centerXAnchor.constraint(equalTo: page.centerXAnchor),
            column.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bar.topAnchor, constant: -20),
            bar.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 28),
            bar.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -28),
            bar.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -26),
        ])
        return page
    }

    // MARK: - Welcome page

    private func makeWelcomePage() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 112).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let title = Self.label("Welcome to \(Self.appName)", size: 30, weight: .bold)
        let subtitle = Self.label(
            "A Mac browser built around profiles, so every part of your life gets its own space.",
            size: 15, color: .secondaryLabelColor
        )

        let features = NSStackView(views: [
            Self.featureRow(
                symbol: "person.2.fill",
                title: "Profiles, Kept Apart",
                body: "Work, personal and everything in between, each with its own sign-ins, history and passwords."
            ),
            Self.featureRow(
                symbol: "arrow.triangle.branch",
                title: "Links Go Where They Belong",
                body: "Rules open each link in the right profile, by the site or by the app you clicked it in."
            ),
            Self.featureRow(
                symbol: "hand.raised.fill",
                title: "Private by Design",
                body: "Built-in content blocking, passkeys and a password manager, and private windows that keep nothing."
            ),
        ])
        features.orientation = .vertical
        features.alignment = .leading
        features.spacing = 22

        let column: [NSView] = [icon, title, subtitle, features]
        let page = makePage(
            content: column,
            trailingButtons: [Self.primaryButton("Continue", target: self, action: #selector(continueFromWelcome(_:)))]
        )
        if let stack = icon.superview as? NSStackView {
            stack.setCustomSpacing(20, after: icon)
            stack.setCustomSpacing(40, after: subtitle)
        }
        return page
    }

    @objc private func continueFromWelcome(_ sender: Any?) {
        present(makeImportPage(), animated: true)
    }

    // MARK: - Import page

    private func makeImportPage() -> NSView {
        existingProfiles = ProfileManager.shared.profiles
        discoverSources()

        let header = Self.iconCluster(Array(uniqueIcons().prefix(4)))
        let title = Self.label("Bring Your Browsing With You", size: 26, weight: .bold)
        let subtitle = Self.label(
            "Choose what to bring over. Nothing changes in your other browsers.",
            size: 13, color: .secondaryLabelColor
        )

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        let list = Self.groupedBox(containing: rowsStack, height: 236)
        reloadRows()

        let fileLabel = Self.label("Or import a file:", size: 12, color: .secondaryLabelColor, alignment: .left)
        let bookmarksFileButton = Self.smallButton("Bookmarks File\u{2026}", target: self, action: #selector(chooseBookmarksFile(_:)))
        let passwordsFileButton = Self.smallButton("Passwords File\u{2026}", target: self, action: #selector(choosePasswordsFile(_:)))
        let fileRow = NSStackView(views: [fileLabel, bookmarksFileButton, passwordsFileButton])
        fileRow.orientation = .horizontal
        fileRow.spacing = 8

        passwordsCheckbox.target = self
        passwordsCheckbox.action = #selector(selectionChanged(_:))
        passwordsCheckbox.state = .on
        passwordsNote.font = .systemFont(ofSize: 11)
        passwordsNote.textColor = .secondaryLabelColor
        passwordsNote.preferredMaxLayoutWidth = Self.contentWidth - 20
        passwordsNote.stringValue = "macOS asks for your login password once for each browser. "
            + "For Safari passwords, export them from the Passwords app, then choose Passwords File."
        let passwords = NSStackView(views: [passwordsCheckbox, passwordsNote])
        passwords.orientation = .vertical
        passwords.alignment = .leading
        passwords.spacing = 4
        passwords.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)

        let options = NSStackView(views: [fileRow, passwords])
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 14

        let page = makePage(
            content: [header, title, subtitle, list, options],
            trailingButtons: [importButton],
            leadingButtons: [Self.secondaryButton(startedAtWelcome ? "Not Now" : "Cancel", target: self, action: #selector(skipImport(_:)))]
        )
        if let stack = header.superview as? NSStackView {
            stack.setCustomSpacing(16, after: header)
            stack.setCustomSpacing(22, after: subtitle)
            stack.setCustomSpacing(16, after: list)
        }
        options.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        refreshControls()
        return page
    }

    private func discoverSources() {
        cleanUpSafariScan()
        let defaultBundleId = OnboardingSourceDiscovery.defaultBrowserBundleId()
        var found: [OnboardingImportSource] = []

        safariNeedsAccess = false
        if OnboardingSourceDiscovery.isSafariInstalled {
            if let result = try? SafariImportScanner.scan() {
                safariScan = result
                found += OnboardingSourceDiscovery.safariSources(from: result, defaultBundleId: defaultBundleId)
            } else {
                safariNeedsAccess = true
            }
        }
        found += OnboardingSourceDiscovery.chromiumSources(defaultBundleId: defaultBundleId)

        // The default browser's rows first; within that, the order found.
        found = found.filter(\.isFromDefaultBrowser) + found.filter { !$0.isFromDefaultBrowser }

        // Chosen files survive a rescan.
        let files = rows.filter { $0.source.isFile }
        let firstExisting = existingProfiles.first.map { Destination.existing(profileId: $0.id) } ?? .newProfile
        // With no other browser as the default (this app already is, or one
        // this app can't import from), only the first row starts checked.
        let anyFromDefault = found.contains(where: \.isFromDefaultBrowser)
        rows = found.enumerated().map { index, source in
            Row(
                source: source,
                isSelected: anyFromDefault ? source.isFromDefaultBrowser : index == 0,
                // The first browser profile fills the profile that is already
                // here; every other one gets a profile of its own.
                destination: index == 0 ? firstExisting : .newProfile
            )
        } + files
    }

    private func uniqueIcons() -> [NSImage] {
        var seen = Set<ObjectIdentifier>()
        var icons: [NSImage] = []
        if safariNeedsAccess {
            icons.append(OnboardingSourceDiscovery.appIcon(bundleId: OnboardingSourceDiscovery.safariBundleId))
        }
        for row in rows where !row.source.isFile {
            // Each browser's rows share one NSImage instance.
            if seen.insert(ObjectIdentifier(row.source.icon)).inserted { icons.append(row.source.icon) }
        }
        return icons
    }

    private func reloadRows() {
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var views: [NSView] = []
        if safariNeedsAccess {
            views.append(makeSafariAccessRow())
        }
        for index in rows.indices {
            views.append(makeSourceRow(at: index))
        }
        if views.isEmpty {
            let empty = Self.label(
                "No other browsers with data to import were found on this Mac. You can still import a file below.",
                size: 13, color: .secondaryLabelColor
            )
            empty.preferredMaxLayoutWidth = Self.contentWidth - 60
            let wrapper = NSStackView(views: [empty])
            wrapper.edgeInsets = NSEdgeInsets(top: 90, left: 30, bottom: 30, right: 30)
            views.append(wrapper)
        }
        for (index, view) in views.enumerated() {
            rowsStack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
            if index < views.count - 1 {
                let separator = NSBox()
                separator.boxType = .separator
                rowsStack.addArrangedSubview(separator)
                separator.leadingAnchor.constraint(equalTo: rowsStack.leadingAnchor, constant: 58).isActive = true
                separator.trailingAnchor.constraint(equalTo: rowsStack.trailingAnchor).isActive = true
            }
        }
    }

    private func makeSourceRow(at index: Int) -> NSView {
        let row = rows[index]
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(rowToggled(_:)))
        checkbox.tag = index
        checkbox.state = row.isSelected ? .on : .off
        checkbox.setAccessibilityLabel(row.source.title)

        let destination = NSPopUpButton(frame: .zero, pullsDown: false)
        destination.controlSize = .small
        destination.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        destination.tag = index
        destination.target = self
        destination.action = #selector(destinationChanged(_:))
        for profile in existingProfiles {
            let item = NSMenuItem(title: "Into \u{201C}\(profile.name)\u{201D}", action: nil, keyEquivalent: "")
            item.representedObject = profile.id
            item.image = Self.colorDot(hex: profile.colorHex)
            destination.menu?.addItem(item)
        }
        if !existingProfiles.isEmpty { destination.menu?.addItem(.separator()) }
        destination.menu?.addItem(withTitle: "Into a New Profile", action: nil, keyEquivalent: "")
        switch row.destination {
        case .existing(let id):
            if let item = destination.itemArray.first(where: { ($0.representedObject as? String) == id }) {
                destination.select(item)
            }
        case .newProfile:
            destination.selectItem(at: destination.numberOfItems - 1)
        }
        destination.isEnabled = row.isSelected

        return Self.rowView(icon: row.source.icon, title: row.source.title, detail: row.source.detail, leading: checkbox, trailing: destination)
    }

    private func makeSafariAccessRow() -> NSView {
        let allow = Self.smallButton("Allow Access\u{2026}", target: self, action: #selector(openFullDiskAccessSettings(_:)))
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return Self.rowView(
            icon: OnboardingSourceDiscovery.appIcon(bundleId: OnboardingSourceDiscovery.safariBundleId),
            title: "Safari",
            detail: "\(Self.appName) needs Full Disk Access to read Safari\u{2019}s bookmarks and history.",
            leading: spacer,
            trailing: allow
        )
    }

    private func refreshControls() {
        let selected = rows.filter(\.isSelected)
        importButton.isEnabled = !selected.isEmpty
        let offersBrowserPasswords = selected.contains {
            if case .chromium(let profile) = $0.source.kind { return profile.hasLoginData }
            return false
        }
        passwordsCheckbox.isEnabled = offersBrowserPasswords
        passwordsNote.textColor = offersBrowserPasswords ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func rowToggled(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        rows[sender.tag].isSelected = sender.state == .on
        if let popup = sender.superview?.subviews.compactMap({ $0 as? NSPopUpButton }).first {
            popup.isEnabled = sender.state == .on
        }
        refreshControls()
    }

    @objc private func destinationChanged(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag) else { return }
        if let id = sender.selectedItem?.representedObject as? String {
            rows[sender.tag].destination = .existing(profileId: id)
        } else {
            rows[sender.tag].destination = .newProfile
        }
    }

    @objc private func selectionChanged(_ sender: Any?) {
        refreshControls()
    }

    @objc private func openFullDiskAccessSettings(_ sender: Any?) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Back from System Settings: look at Safari again.
    func windowDidBecomeKey(_ notification: Notification) {
        guard safariNeedsAccess, !isImporting, importButton.window === window,
              let probe = try? SafariImportScanner.scan() else { return }
        try? FileManager.default.removeItem(at: probe.tempDirectory)
        discoverSources()
        // Safari rows are new, so every row's tag has moved.
        reloadRows()
        refreshControls()
    }

    @objc private func chooseBookmarksFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.message = "Choose a bookmarks file exported from another browser."
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let html = try? String(contentsOf: url) else {
                self.showSheetAlert(title: "Couldn\u{2019}t Read File", message: "\(url.lastPathComponent) couldn\u{2019}t be read as text.")
                return
            }
            let nodes = NetscapeBookmarkParser.parse(html)
            guard !nodes.isEmpty else {
                self.showSheetAlert(title: "No Bookmarks Found", message: "\(url.lastPathComponent) doesn\u{2019}t contain any bookmarks.")
                return
            }
            self.addFileRow(OnboardingSourceDiscovery.bookmarksFileSource(url: url, nodes: nodes))
        }
    }

    @objc private func choosePasswordsFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = "Choose a passwords CSV exported from the Passwords app or another browser."
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let text = try? String(contentsOf: url),
                  let entries = try? PasswordCSVParser.parse(csv: text) else {
                self.showSheetAlert(title: "Not a Password Export", message: "\(url.lastPathComponent) doesn\u{2019}t look like a password export.")
                return
            }
            guard !entries.isEmpty else {
                self.showSheetAlert(title: "No Passwords Found", message: "\(url.lastPathComponent) doesn\u{2019}t contain any passwords.")
                return
            }
            self.addFileRow(OnboardingSourceDiscovery.passwordsFileSource(url: url, entries: entries))
        }
    }

    private func addFileRow(_ source: OnboardingImportSource) {
        // A file chosen twice replaces its first row.
        rows.removeAll { row in
            switch (row.source.kind, source.kind) {
            case (.bookmarksFile(let a, _), .bookmarksFile(let b, _)), (.passwordsFile(let a, _), .passwordsFile(let b, _)):
                return a == b
            default:
                return false
            }
        }
        let destination = WindowManager.shared.keyBrowserWindowController.map { Destination.existing(profileId: $0.profile.id) }
            ?? existingProfiles.first.map { Destination.existing(profileId: $0.id) }
            ?? .newProfile
        rows.append(Row(source: source, isSelected: true, destination: destination))
        reloadRows()
        refreshControls()
        DispatchQueue.main.async { [weak self] in
            guard let self, let scroll = self.rowsStack.enclosingScrollView, let document = scroll.documentView else { return }
            document.scroll(NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
        }
    }

    private func showSheetAlert(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    @objc private func skipImport(_ sender: Any?) {
        guard startedAtWelcome else {
            close()
            return
        }
        outcomes = []
        cleanUpSafariScan()
        dropPasswordFiles()
        present(makeDonePage(), animated: true)
    }

    // MARK: - Importing

    @objc private func performImport(_ sender: Any?) {
        let selected = rows.filter(\.isSelected)
        guard !selected.isEmpty, !isImporting else { return }
        isImporting = true
        outcomes = []
        window?.standardWindowButton(.closeButton)?.isEnabled = false
        present(makeProgressPage(), animated: true)

        var keys: [String: ChromiumImportWindowController.PasswordKeyRead] = [:]
        var importedPasswordFiles: [URL] = []
        let includeBrowserPasswords = passwordsCheckbox.state == .on

        func step(_ index: Int) {
            guard index < selected.count else {
                for case .key(let key) in keys.values { key.wipe() }
                finishImport(fullyImportedPasswordFiles: importedPasswordFiles)
                return
            }
            let row = selected[index]
            progressLabel.stringValue = "Importing \(row.source.title)\u{2026}"
            // One turn to paint the label, then the import itself.
            DispatchQueue.main.async { [self] in
                let profile = resolveDestination(for: row)
                var lines: [String] = []
                switch row.source.kind {
                case .safari(let source):
                    let counts = SafariImportWindowController.importProfile(source, into: profile)
                    lines.append("Bookmarks: \(counts.bookmarks) imported, plus \(counts.favorites) favourite\(counts.favorites == 1 ? "" : "s").")
                    lines.append("History: \(OnboardingSourceDiscovery.count(counts.history, "visit")) imported.")
                case .chromium(let source):
                    if includeBrowserPasswords, source.hasLoginData {
                        let name = source.browser.name
                        if keys[name] == nil { keys[name] = ChromiumImportWindowController.readPasswordKey(for: source.browser) }
                        switch keys[name]! {
                        case .key(let key):
                            lines.append(ChromiumImportWindowController.importPasswords(from: source, into: profile, overwriteExisting: false, key: key))
                        case .unavailable(let line):
                            lines.append(line)
                        }
                    }
                    if source.hasBookmarks {
                        lines.append(ChromiumImportWindowController.importBookmarks(from: source, into: profile))
                    }
                    if source.hasHistory {
                        lines.append(ChromiumImportWindowController.importHistory(from: source, into: profile))
                    }
                case .bookmarksFile(_, let nodes):
                    lines.append("Bookmarks: \(importBookmarksFile(nodes, into: profile)) imported into \u{201C}Imported Bookmarks\u{201D}.")
                case .passwordsFile(let url, let entries):
                    let result = PasswordImportCoordinator.importEntries(entries, into: profile, overwriteExisting: false)
                    var line = "Passwords: \(result.importedCount) imported"
                    if result.skippedAsDuplicateCount > 0 { line += ", \(result.skippedAsDuplicateCount) already saved" }
                    let skipped = result.unusableCount + result.failedCount
                    if skipped > 0 { line += ", \(skipped) skipped" }
                    lines.append(line + ".")
                    if result.importedCount == entries.count { importedPasswordFiles.append(url) }
                }
                outcomes.append(Outcome(title: "\(row.source.title) \u{2192} \(profile.name)", icon: row.source.icon, lines: lines))
                step(index + 1)
            }
        }
        DispatchQueue.main.async { step(0) }
    }

    private func resolveDestination(for row: Row) -> Profile {
        if case .existing(let id) = row.destination,
           let profile = ProfileManager.shared.profiles.first(where: { $0.id == id }) {
            return profile
        }
        // Chosen as new, or the chosen profile was deleted while this was open.
        return ProfileManager.shared.createProfile(name: row.source.newProfileName, colorHex: ProfileManager.shared.nextUnusedColor())
    }

    private func importBookmarksFile(_ nodes: [ImportedBookmarkNode], into profile: Profile) -> Int {
        let stores = ProfileDataStoreManager.shared.stores(for: profile)
        let folderId = try? stores.bookmarks.addFolder(title: "Imported Bookmarks", parentId: nil)
        let inserted = BookmarkImporter.importNodes(
            nodes,
            into: stores.bookmarks,
            destinationParentId: folderId,
            favoritesFolderId: FavoritesFolder.id(in: stores.bookmarks)
        )
        for host in Set(inserted.compactMap { URL(string: $0)?.host }) {
            FaviconLoader.shared.loadFavicon(host: host, hintURL: nil, profileId: profile.id) { _ in }
        }
        return inserted.count
    }

    private func finishImport(fullyImportedPasswordFiles: [URL]) {
        cleanUpSafariScan()
        dropPasswordFiles()
        isImporting = false
        window?.standardWindowButton(.closeButton)?.isEnabled = true
        present(makeDonePage(), animated: true)
        // The plaintext file is the only other copy, so deleting it is only
        // offered once every entry in it is saved here.
        for url in fullyImportedPasswordFiles {
            SafariImportWindowController.offerToDeletePasswordCSV(at: url)
        }
    }

    private func makeProgressPage() -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        progressLabel.font = .systemFont(ofSize: 15, weight: .medium)
        progressLabel.alignment = .center
        progressLabel.stringValue = "Getting ready\u{2026}"
        let hint = Self.label("This can take a minute for a long history.", size: 12, color: .secondaryLabelColor)

        let spacer = NSView()
        spacer.heightAnchor.constraint(equalToConstant: 150).isActive = true
        return makePage(content: [spacer, spinner, progressLabel, hint], trailingButtons: [])
    }

    // MARK: - Done page

    private func makeDonePage() -> NSView {
        let symbol = NSImageView()
        symbol.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 60, weight: .regular))
        symbol.contentTintColor = .systemGreen

        let title = Self.label(outcomes.isEmpty ? "Ready When You Are" : "You\u{2019}re All Set", size: 28, weight: .bold)
        let subtitle = Self.label(
            outcomes.isEmpty
                ? "You can bring over another browser\u{2019}s data at any time with File > Import Browser Data\u{2026}"
                : "Here\u{2019}s what came over.",
            size: 13, color: .secondaryLabelColor
        )

        var content: [NSView] = [symbol, title, subtitle]
        if !outcomes.isEmpty {
            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            for (index, outcome) in outcomes.enumerated() {
                let row = Self.rowView(
                    icon: outcome.icon,
                    title: outcome.title,
                    detail: outcome.lines.joined(separator: "\n"),
                    leading: nil,
                    trailing: nil
                )
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
                if index < outcomes.count - 1 {
                    let separator = NSBox()
                    separator.boxType = .separator
                    stack.addArrangedSubview(separator)
                    separator.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 58).isActive = true
                    separator.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
                }
            }
            content.append(Self.groupedBox(containing: stack, height: 220))
        } else {
            let spacer = NSView()
            spacer.heightAnchor.constraint(equalToConstant: 24).isActive = true
            content.append(spacer)
        }

        let section = makeDefaultBrowserSection()
        defaultBrowserSection = section
        content.append(section)

        let finish = Self.primaryButton(
            opensBrowserWindowOnClose ? "Start Browsing" : "Done",
            target: self,
            action: #selector(finish(_:))
        )
        let page = makePage(content: content, trailingButtons: [finish])
        if let stack = symbol.superview as? NSStackView {
            stack.setCustomSpacing(16, after: symbol)
            stack.setCustomSpacing(22, after: subtitle)
            if let list = content.dropFirst(3).first { stack.setCustomSpacing(22, after: list) }
        }
        section.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        if outcomes.isEmpty, let stack = symbol.superview as? NSStackView {
            stack.edgeInsets = NSEdgeInsets(top: 110, left: 0, bottom: 0, right: 0)
        }
        return page
    }

    private func makeDefaultBrowserSection() -> NSView {
        let icon = NSApp.applicationIconImage ?? NSImage()
        if OnboardingSourceDiscovery.isThisAppDefaultBrowser {
            let check = NSImageView()
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            check.contentTintColor = .systemGreen
            return Self.groupedBox(
                containing: Self.rowView(
                    icon: icon,
                    title: "\(Self.appName) is your default browser",
                    detail: "Links you click in other apps open here, in the right profile.",
                    leading: nil,
                    trailing: check
                ),
                height: nil
            )
        }
        let button = Self.smallButton("Use as Default", target: self, action: #selector(makeDefaultBrowser(_:)))
        return Self.groupedBox(
            containing: Self.rowView(
                icon: icon,
                title: "Make \(Self.appName) your default browser",
                detail: "Links you click in other apps open here, in the right profile.",
                leading: nil,
                trailing: button
            ),
            height: nil
        )
    }

    /// Only "http" matters for default-browser purposes; macOS asks the
    /// user to confirm with its own dialog (see RoutingRulesPaneController).
    @objc private func makeDefaultBrowser(_ sender: Any?) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { [weak self] error in
            if let error {
                NSLog("Browser: setDefaultApplication(toOpenURLsWithScheme: \"http\") failed: %@", error.localizedDescription)
            }
            DispatchQueue.main.async { self?.refreshDefaultBrowserSection() }
        }
    }

    private func refreshDefaultBrowserSection() {
        guard let old = defaultBrowserSection, let stack = old.superview as? NSStackView,
              let index = stack.arrangedSubviews.firstIndex(of: old) else { return }
        let new = makeDefaultBrowserSection()
        stack.removeArrangedSubview(old)
        old.removeFromSuperview()
        stack.insertArrangedSubview(new, at: index)
        new.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        defaultBrowserSection = new
    }

    @objc private func finish(_ sender: Any?) {
        close()
    }

    // MARK: - Cleanup

    private func cleanUpSafariScan() {
        if let safariScan { try? FileManager.default.removeItem(at: safariScan.tempDirectory) }
        safariScan = nil
    }

    private func dropPasswordFiles() {
        rows.removeAll {
            if case .passwordsFile = $0.source.kind { return true }
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        cleanUpSafariScan()
        rows = []
        outcomes = []
        currentPage?.removeFromSuperview()
        currentPage = nil
        if opensBrowserWindowOnClose, WindowManager.shared.windowControllers.isEmpty {
            opensBrowserWindowOnClose = false
            WindowManager.shared.openNewWindow(profile: ProfileManager.shared.fallbackProfile)
        }
        opensBrowserWindowOnClose = false
    }

    // MARK: - Building blocks

    private static func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        alignment: NSTextAlignment = .center
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = alignment
        field.isSelectable = false
        field.preferredMaxLayoutWidth = contentWidth
        return field
    }

    private static func stylePrimary(_ button: NSButton) {
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    private static func primaryButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        stylePrimary(button)
        return button
    }

    private static func secondaryButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\u{1b}"
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        return button
    }

    private static func smallButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        return button
    }

    private static func featureRow(symbol: String, title: String, body: String) -> NSView {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 26, weight: .regular))
        image.contentTintColor = .controlAccentColor
        image.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let titleLabel = label(title, size: 13, weight: .semibold, alignment: .left)
        let bodyLabel = label(body, size: 13, color: .secondaryLabelColor, alignment: .left)
        bodyLabel.preferredMaxLayoutWidth = 400
        bodyLabel.widthAnchor.constraint(equalToConstant: 400).isActive = true
        let text = NSStackView(views: [titleLabel, bodyLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [image, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    /// A list row: optional control, app icon, title and detail, optional
    /// control on the far side.
    private static func rowView(icon: NSImage, title: String, detail: String, leading: NSView?, trailing: NSView?) -> NSView {
        let iconView = NSImageView(image: icon)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 32).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 32).isActive = true

        let titleLabel = label(title, size: 13, weight: .medium, alignment: .left)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        let detailLabel = label(detail, size: 11, color: .secondaryLabelColor, alignment: .left)
        detailLabel.preferredMaxLayoutWidth = 340
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = []
        if let leading { views.append(leading) }
        views += [iconView, text]
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        if let trailing {
            row.addView(trailing, in: .trailing)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        return row
    }

    /// The rounded, inset "grouped" background System Settings uses for
    /// lists. With a height, the content scrolls inside it.
    private static func groupedBox(containing content: NSView, height: CGFloat?) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 10
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6)
        box.contentViewMargins = .zero
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        let inner = box.contentView ?? box
        content.translatesAutoresizingMaskIntoConstraints = false
        guard let height else {
            inner.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: inner.topAnchor),
                content.bottomAnchor.constraint(equalTo: inner.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
            ])
            return box
        }

        box.heightAnchor.constraint(equalToConstant: height).isActive = true
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        inner.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: inner.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -1),
            scroll.leadingAnchor.constraint(equalTo: inner.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: inner.trailingAnchor),
        ])
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        return box
    }

    /// Up to four app icons, overlapping slightly, as the import page's header.
    private static func iconCluster(_ icons: [NSImage]) -> NSView {
        guard !icons.isEmpty else {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 44, weight: .light))
            image.contentTintColor = .controlAccentColor
            return image
        }
        let stack = NSStackView(views: icons.map { icon in
            let view = NSImageView(image: icon)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.widthAnchor.constraint(equalToConstant: 64).isActive = true
            view.heightAnchor.constraint(equalToConstant: 64).isActive = true
            return view
        })
        stack.orientation = .horizontal
        stack.spacing = -12
        return stack
    }

    private static func colorDot(hex: String) -> NSImage {
        let color = NSColor(hex: hex) ?? .controlAccentColor
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
