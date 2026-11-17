import AppKit

/// The toolbar button that says an update is available. A background check
/// never opens a dialog; this button is how the user hears about a release,
/// and clicking it opens the update dialog.
///
/// One per window, attached like the downloads button. It is never shown in
/// an agent's window.
final class UpdateToolbarController: NSObject {
    /// Slot 0 and up belong to Reader, downloads, passwords, autofill and
    /// extensions; a lower slot puts this one nearest the trailing group.
    private static let slot = -1

    private weak var window: BrowserWindow?
    private var button: NSButton?
    private var observer: NSObjectProtocol?

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func attach(to window: BrowserWindow) {
        self.window = window
        observer = NotificationCenter.default.addObserver(
            forName: .updateStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The updater starts after the launch's first windows exist, and it
        // posts once it has restored a known release.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    @MainActor
    private func refresh() {
        guard let window, let controller = window.windowController as? BrowserWindowController else { return }
        // A local build is never offered a release: its template version
        // always looks older than the newest one.
        let updates = UpdateCoordinator.shared.controller
        let release = WindowManager.shared.isAgentOwned(controller) || updates?.isReleaseBuild != true
            ? nil : updates?.unskippedRelease
        guard let release else {
            button?.isHidden = true
            return
        }
        let button = button ?? makeButton(in: window, controller: controller)
        let label = "Update available: Browser \(release.version)"
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.isHidden = false
    }

    @MainActor
    private func makeButton(in window: BrowserWindow, controller: BrowserWindowController) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Update available")!,
            target: self, action: #selector(buttonTapped))
        button.applyChromeAppearance(.glass)
        button.contentTintColor = .controlAccentColor
        button.autoresizingMask = [.minXMargin, .minYMargin]
        window.contentView?.addSubview(button)
        controller.placeTrailingToolbarControl(button, slot: Self.slot)
        self.button = button
        return button
    }

    @objc private func buttonTapped() {
        MainActor.assumeIsolated { UpdateCoordinator.shared.presentAvailableUpdate() }
    }
}
