import AppKit

/// The app's entry points for updates: the "Check for Updates…" menu item,
/// the toolbar button, Settings, launch and quit. `UpdateController` holds
/// the state; `UpdateWindowController` is the dialog.
///
/// The flow, as in myterm: a background check finds a release and shows a
/// button in every window's toolbar, never a dialog. The dialog opens only
/// from that button or the menu. "Update Now" downloads, verifies and stages
/// the release; then "Restart Now" installs it at once, and "Later" installs
/// it the next time Browser quits.
final class UpdateCoordinator: NSObject, NSMenuItemValidation {
    static let shared = UpdateCoordinator()

    /// `nil` when updates are off for this launch (see `disabledReason`).
    private(set) var controller: UpdateController?
    private var window: UpdateWindowController?
    private var restartError: String?

    private override init() {
        super.init()
    }

    /// Starts the updater, unless this launch must never replace a bundle.
    /// Call it once the launch's own windows are up: it confirms a just-
    /// installed update's startup, and the helper waits for that.
    @MainActor
    func start() {
        guard controller == nil else { return }
        if let reason = Self.disabledReason() {
            NSLog("Browser: updates are off for this launch (%@)", reason)
            return
        }
        let controller = UpdateController()
        self.controller = controller
        confirmInstalledUpdate()
        if let message = ApplicationUpdate.takeInstallError(beside: Bundle.main.bundleURL) {
            controller.reportInstallFailure(message)
            showWindow(release: nil)
        }
        let app = Bundle.main.bundleURL
        let pending = controller.stagedUpdate?.manifestURL
        DispatchQueue.global(qos: .utility).async {
            ApplicationUpdate.pruneCompletedUpdates(for: app, keeping: pending)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { UpdateCoordinator.shared.installOnQuit() }
        }
        controller.start()
    }

    /// Tells a waiting helper that this new version started, so it keeps it
    /// rather than putting the previous app back.
    @MainActor
    private func confirmInstalledUpdate() {
        guard let controller,
              let plan = UpdateStartupTrial.pending(beside: Bundle.main.bundleURL, version: controller.currentVersion) else { return }
        do {
            try UpdateStartupTrial.report(.loaded, plan: plan)
            try UpdateStartupTrial.commit(plan)
        } catch {
            NSLog("Browser: could not confirm the update's startup: %@", error.localizedDescription)
        }
    }

    /// Why updates are off for this launch, or `nil` when they are on.
    ///
    /// 1. A `--profiles-root` launch is a scratch or test instance, a copy
    ///    under /tmp. A check from one is noise, and installing into it is worse.
    /// 2. A bundle in the CMake output tree is the build's own product.
    ///    Replacing it would swap the code under development for the last
    ///    release, and the next build would overwrite that anyway.
    private static func disabledReason() -> String? {
        if ProfilesRootResolver.explicitOverride(arguments: CommandLine.arguments) != nil {
            return "scratch launch: --profiles-root was passed"
        }
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/build/Sources/App/") || bundlePath.contains("/build-release/Sources/App/") {
            return "running from the build output tree at \(bundlePath)"
        }
        return nil
    }

    // MARK: - Actions

    /// The "Check for Updates…" menu item: always checks, and always answers.
    @objc func checkForUpdates(_ sender: Any?) {
        MainActor.assumeIsolated {
            guard let controller else { return }
            Task { @MainActor in
                switch await controller.check() {
                case .available(let release): self.showWindow(release: release)
                case .upToDate(let version): self.showUpToDate(version)
                case .failed(let reason): self.showCheckFailed(reason)
                case .idle, .checking: break
                }
            }
        }
    }

    /// The toolbar button: the known release, or a fresh check.
    @MainActor
    func presentAvailableUpdate() {
        guard let release = controller?.status.release else { return checkForUpdates(nil) }
        showWindow(release: release)
    }

    @MainActor
    func showWindow(release: AppRelease?) {
        guard let controller else { return }
        if let window, window.release == release || release == nil {
            window.showWindow(nil)
            window.window?.makeKeyAndOrderFront(nil)
            return
        }
        window?.close()
        let window = UpdateWindowController(controller: controller, coordinator: self, release: release)
        self.window = window
        window.showWindow(nil)
        window.window?.center()
        window.window?.makeKeyAndOrderFront(nil)
        AppActivation.activate()
    }

    @MainActor
    func windowDidClose(_ closed: UpdateWindowController) {
        if window === closed { window = nil }
    }

    @MainActor
    private func showUpToDate(_ version: AppVersion) {
        let alert = NSAlert()
        alert.messageText = "Browser is up to date"
        alert.informativeText = "Version \(version) is the newest release."
        alert.runModal()
    }

    @MainActor
    private func showCheckFailed(_ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not check for updates"
        alert.informativeText = reason
        alert.runModal()
    }

    @MainActor
    func prepareUpdate(_ release: AppRelease) {
        restartError = nil
        Task { await controller?.install(release: release) }
    }

    @MainActor
    var lastRestartError: String? { restartError }

    /// Checks the staged app again, starts the helper, and quits. The helper
    /// waits for this process to exit, installs, and opens the new version;
    /// the session restores from session.json as on any launch.
    @MainActor
    func restartAfterUpdate() {
        guard let controller, controller.canRestartAfterUpdate else { return }
        restartError = nil
        Task { @MainActor in
            do {
                let helper = try await controller.verifiedRestartHelper()
                try helper.run()
                controller.markRestartingForUpdate()
                NSApp.terminate(nil)
            } catch {
                restartError = "Could not restart to update: \(error.localizedDescription)"
                NotificationCenter.default.post(name: .updateStateDidChange, object: controller)
            }
        }
    }

    /// Hands a prepared update to the helper as Browser quits. Runs from
    /// `willTerminateNotification`, just before `exit(0)`, so it does only
    /// the cheap checks; the helper checks everything again before it swaps.
    @MainActor
    private func installOnQuit() {
        guard let controller, controller.stagedUpdate != nil, !controller.isRestartingForUpdate,
              controller.installation != .running else { return }
        do {
            try controller.helper(relaunch: false).run()
        } catch {
            controller.disarmPreparedUpdate("The prepared update could not be installed. \(error.localizedDescription)")
            NSLog("Browser: prepared update not handed off at quit: %@", error.localizedDescription)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return MainActor.assumeIsolated { controller.map { $0.status != .checking } ?? false }
    }
}
