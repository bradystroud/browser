import AppKit

/// The "iCloud Passwords" rows of Settings > Passwords: one place to install
/// Apple's iCloud Passwords extension for the profile the pane has selected,
/// and to see whether it is running. The extension and the macOS helper it
/// talks to do the filling; this app's own password manager is separate.
///
/// Which state to show is `ICloudPasswordsExtension.status`; this class only
/// reads the extension manager, draws the answer and forwards the buttons.
final class ICloudPasswordsSection: NSObject {
    private static let id = ICloudPasswordsExtension.storeID

    private let statusLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isSelectable = false
        label.preferredMaxLayoutWidth = SettingsForm.controlColumnWidth
        return label
    }()
    private let setUpButton = NSButton(title: "Set Up…", target: nil, action: nil)
    private let turnOnButton = NSButton(title: "Turn On", target: nil, action: nil)
    private let pairButton = NSButton(title: "Pair…", target: nil, action: nil)
    private let optionsButton = NSButton(title: "Options…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove…", target: nil, action: nil)
    private let manageButton = NSButton(title: "Manage Extensions…", target: nil, action: nil)
    private var buttonRow: NSGridRow?

    private var profile: Profile?
    private var installing = false
    private var observer: NSObjectProtocol?

    private weak var hostView: NSView?

    deinit {
        observer.map { NotificationCenter.default.removeObserver($0) }
    }

    func install(in form: SettingsForm, hostView: NSView) {
        self.hostView = hostView
        for (button, action) in [
            (setUpButton, #selector(setUp)), (turnOnButton, #selector(turnOn)), (pairButton, #selector(pair)),
            (optionsButton, #selector(openOptions)), (removeButton, #selector(remove)),
            (manageButton, #selector(manage)),
        ] {
            button.target = self
            button.action = action
        }
        form.beginSection()
        form.addRow("iCloud Passwords:", statusLabel)
        buttonRow = form.addRow(nil, setUpButton, turnOnButton, pairButton, optionsButton, manageButton, removeButton)
        observer = NotificationCenter.default.addObserver(
            forName: .browserExtensionsDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, (notification.object as? String) == self.profile?.id else { return }
            self.refresh()
        }
        refresh()
    }

    func setProfile(_ profile: Profile?) {
        self.profile = profile
        refresh()
    }

    // MARK: - State

    private var manager: EngineExtensionManager? { ExtensionsCoordinator.shared.manager }

    private var summary: EngineExtensionSummary? {
        guard let profile else { return nil }
        return manager?.extensions(profileId: profile.id).first { $0.id == Self.id }
    }

    private var status: ICloudPasswordsExtension.Status {
        let found = summary
        return ICloudPasswordsExtension.status(
            extensionsAvailable: manager != nil,
            hasEntitlement: PlatformPasskeyBroker.hasBrowserPasskeyEntitlement,
            installed: found != nil,
            enabled: found?.isEnabled ?? false,
            loaded: found?.isLoaded ?? false,
            errorCount: found?.errors.count ?? 0,
            paired: found?.isSetUp == true
        )
    }

    private func refresh() {
        let status = status
        let text: String
        switch status {
        case .needsNewerMacOS:
            text = "Needs macOS 15.4 or later."
        case .unavailableInThisBuild:
            text = "iCloud Passwords is not available in this build of Browser."
        case .notInstalled:
            text = installing
                ? "Setting up…"
                : "Fill and save passwords from the Passwords app, with Apple's iCloud Passwords extension. Works in WebKit tabs."
        case .ready:
            text = "On, not paired yet. Click Pair… and enter the code that macOS shows. The iCloud Passwords button appears in the toolbar once this profile is paired."
        case .paired:
            text = "On and paired. Fills from the Passwords app in WebKit tabs."
        case .turnedOff:
            text = "The extension is turned off."
        case .hasProblem:
            text = "The extension has a problem and is not running."
        }
        statusLabel.stringValue = text

        let hasProfile = profile != nil
        setUpButton.isHidden = status != .notInstalled
        setUpButton.isEnabled = hasProfile && !installing
        turnOnButton.isHidden = status != .turnedOff
        pairButton.isHidden = status != .ready
        let running = status == .ready || status == .paired
        optionsButton.isHidden = !(running && summary?.hasOptionsPage == true)
        removeButton.isHidden = !running
        manageButton.isHidden = status != .hasProblem
        let anyButton = [setUpButton, turnOnButton, pairButton, optionsButton, removeButton, manageButton].contains { !$0.isHidden }
        buttonRow?.isHidden = !anyButton
    }

    // MARK: - Actions

    @objc private func setUp() {
        guard let profile, let manager, !installing else { return }
        installing = true
        refresh()
        let window = hostView?.window
        Task { @MainActor [weak self] in
            defer {
                self?.installing = false
                self?.refresh()
            }
            do {
                try await manager.installFromWebStore(ICloudPasswordsExtension.storeLink, profileId: profile.id)
                // Its toolbar button shows once the profile is paired.
                manager.setPinned(true, extensionId: ICloudPasswordsExtension.storeID, profileId: profile.id)
            } catch {
                ExtensionsToolbarController.report(error, in: window)
            }
        }
    }

    @objc private func turnOn() {
        guard let profile else { return }
        manager?.setEnabled(true, extensionId: Self.id, profileId: profile.id)
    }

    /// Pairing happens in the extension's own popup, which asks macOS for a
    /// code; it opens over a window of this profile.
    @objc private func pair() {
        guard let profile else { return }
        ExtensionsCoordinator.shared.openPopup(extensionId: Self.id, profile: profile)
    }

    @objc private func openOptions() {
        guard let profile else { return }
        manager?.openOptionsPage(extensionId: Self.id, profileId: profile.id)
    }

    @objc private func remove() {
        guard let profile, NSAlert.confirmDestructive(
            message: "Remove iCloud Passwords?",
            informativeText: "The extension is removed from the profile \"\(profile.name)\". Your passwords in the Passwords app are not changed.",
            confirmTitle: "Remove"
        ) else { return }
        manager?.remove(extensionId: Self.id, profileId: profile.id)
    }

    @objc private func manage() {
        guard let profile else { return }
        ExtensionsWindowManager.shared.show(for: profile)
    }
}
