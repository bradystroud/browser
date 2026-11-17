import AppKit

/// The update dialog. It stays open while an update downloads, and closing
/// it ("Later") never cancels anything: a prepared update installs when
/// Browser quits.
///
/// `release` is `nil` only when the dialog reports an install that failed at
/// the last quit and no newer release is known yet.
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    let release: AppRelease?
    private let controller: UpdateController
    private weak var coordinator: UpdateCoordinator?
    private var observer: NSObjectProtocol?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let detailsToggle = NSButton()
    private let logScroll = NSScrollView()
    private let logView = NSTextView()
    private let releaseNotesButton = NSButton()
    private let skipButton = NSButton()
    private let laterButton = NSButton()
    private let primaryButton = NSButton()

    private enum Primary { case update, retry, restart, openPage, checkAgain }
    private var primary: Primary = .update

    @MainActor
    init(controller: UpdateController, coordinator: UpdateCoordinator, release: AppRelease?) {
        self.controller = controller
        self.coordinator = coordinator
        self.release = release
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildViews(in: window)
        observer = NotificationCenter.default.addObserver(
            forName: .updateStateDidChange, object: controller, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { coordinator?.windowDidClose(self) }
    }

    // MARK: - Layout

    @MainActor
    private func buildViews(in window: NSWindow) {
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        subtitleLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        errorLabel.textColor = .systemRed
        errorLabel.isSelectable = true
        statusLabel.isSelectable = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        let titleRow = NSStackView(views: [icon, titleLabel])
        titleRow.spacing = 8

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        statusIcon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        let statusRow = NSStackView(views: [statusIcon, spinner, statusLabel])
        statusRow.spacing = 6
        statusRow.alignment = .firstBaseline

        detailsToggle.setButtonType(.pushOnPushOff)
        detailsToggle.bezelStyle = .disclosure
        detailsToggle.title = ""
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)
        let detailsTitle = NSTextField(labelWithString: "Details")
        detailsTitle.textColor = .secondaryLabelColor
        let detailsRow = NSStackView(views: [detailsToggle, detailsTitle])
        detailsRow.spacing = 4

        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.isHidden = true
        logScroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        logScroll.setAccessibilityLabel("Update log")

        configure(releaseNotesButton, title: "Release Notes", action: #selector(openReleaseNotes))
        releaseNotesButton.bezelStyle = .inline
        configure(skipButton, title: "Skip This Version", action: #selector(skipVersion))
        configure(laterButton, title: "Later", action: #selector(later))
        laterButton.keyEquivalent = "\u{1b}"
        configure(primaryButton, title: "Update Now", action: #selector(primaryAction))
        primaryButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [releaseNotesButton, skipButton, spacer, laterButton, primaryButton])
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleRow, subtitleLabel, statusRow, progressBar, detailLabel,
                                        errorLabel, detailsRow, logScroll, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(6, after: titleRow)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [subtitleLabel, progressBar, detailLabel, errorLabel, logScroll, buttonRow, statusRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 540),
        ])
        window.contentView = content
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    // MARK: - State

    @MainActor
    private func refresh() {
        let installation = release.map { controller.installation(for: $0) } ?? controller.installation
        if let release {
            titleLabel.stringValue = "Browser \(release.version) is available"
            if controller.route == .native {
                subtitleLabel.stringValue = "You have \(controller.currentVersion). The update is downloaded and checked first, and installs when Browser restarts."
            } else if !controller.isReleaseBuild {
                subtitleLabel.stringValue = "This copy was built locally, so it does not update itself. The release page has the download."
            } else {
                subtitleLabel.stringValue = "You have \(controller.currentVersion). This copy cannot replace itself, because it cannot write to its own folder. Move Browser to your Applications folder, or download the new version from the release page."
            }
        } else {
            titleLabel.stringValue = "The update was not installed"
            subtitleLabel.stringValue = "You still have \(controller.currentVersion). Nothing was changed."
        }

        spinner.stopAnimation(nil)
        statusIcon.isHidden = true
        progressBar.isHidden = true
        detailLabel.isHidden = true
        statusLabel.textColor = .labelColor

        switch installation {
        case .ready:
            statusLabel.stringValue = "Your windows and tabs are saved and come back after the restart."
            statusLabel.isHidden = controller.route != .native
        case .running:
            statusLabel.isHidden = false
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Preparing the update…"
            if let fraction = controller.downloadFraction {
                progressBar.isHidden = false
                progressBar.doubleValue = fraction
            }
            detailLabel.isHidden = false
            detailLabel.stringValue = controller.installationOutput.split(separator: "\n").last.map(String.init) ?? "Starting…"
        case .installed:
            statusLabel.isHidden = false
            statusIcon.isHidden = false
            statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemGreen
            statusLabel.stringValue = "The update is ready. Restart to finish."
            detailLabel.isHidden = false
            detailLabel.stringValue = "If you do not restart now, the update installs the next time you quit Browser."
        case .failed(let reason):
            statusLabel.isHidden = false
            statusIcon.isHidden = false
            statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            statusIcon.contentTintColor = .systemRed
            statusLabel.stringValue = reason
            statusLabel.textColor = .systemRed
        }
        if controller.isPreparingRestart {
            spinner.startAnimation(nil)
            statusIcon.isHidden = true
            statusLabel.stringValue = "Checking the update again before the restart…"
        }

        let error = coordinator?.lastRestartError
        errorLabel.stringValue = error ?? ""
        errorLabel.isHidden = error == nil
        logView.string = controller.installationOutput
        logView.scrollToEndOfDocument(nil)

        releaseNotesButton.isHidden = release == nil
        skipButton.isHidden = release == nil || installation == .installed
        skipButton.isEnabled = installation != .running
        let busy = installation == .running || controller.isPreparingRestart
        laterButton.title = release == nil ? "Close" : "Later"
        laterButton.isEnabled = !busy
        primaryButton.isEnabled = !busy

        if release == nil {
            primary = .checkAgain
        } else if controller.route != .native {
            primary = .openPage
        } else {
            switch installation {
            case .installed: primary = .restart
            case .failed: primary = .retry
            case .ready, .running: primary = .update
            }
        }
        primaryButton.title = switch primary {
        case .update: "Update Now"
        case .retry: "Try Again"
        case .restart: "Restart Now"
        case .openPage: "Open Release Page"
        case .checkAgain: "Check for Updates"
        }
        window?.layoutIfNeeded()
        if let window, let content = window.contentView {
            window.setContentSize(content.fittingSize)
        }
    }

    // MARK: - Actions

    @objc private func toggleDetails() {
        logScroll.isHidden = detailsToggle.state != .on
        MainActor.assumeIsolated { refresh() }
    }

    @objc private func openReleaseNotes() {
        guard let release else { return }
        openInBrowser(release.releaseURL)
    }

    @objc private func skipVersion() {
        guard let release else { return }
        MainActor.assumeIsolated { controller.skip(release) }
        close()
    }

    @objc private func later() {
        close()
    }

    @objc private func primaryAction() {
        MainActor.assumeIsolated {
            switch primary {
            case .update, .retry:
                if let release { coordinator?.prepareUpdate(release) }
            case .restart:
                coordinator?.restartAfterUpdate()
            case .openPage:
                if let release { openInBrowser(release.releaseURL) }
                close()
            case .checkAgain:
                close()
                coordinator?.checkForUpdates(nil)
            }
        }
    }

    /// Opens the page in this browser: a new tab in the frontmost window, or
    /// a new window in the fallback profile when none is open.
    private func openInBrowser(_ url: URL) {
        if let window = WindowManager.shared.keyBrowserWindowController {
            window.addTab(url: url.absoluteString, makeActive: true)
            window.window?.makeKeyAndOrderFront(nil)
        } else {
            WindowManager.shared.openNewWindow(profile: ProfileManager.shared.fallbackProfile, initialURL: url.absoluteString)
        }
    }
}
