import AppKit
import Sparkle

/// Sparkle wiring (browser-wc7). The app is Developer ID distributed outside
/// the App Store, so nothing updates it unless it updates itself: before
/// this, every downloaded copy stayed on whatever version it was installed
/// at, forever.
///
/// Sparkle is driven through `SPUUpdater` directly rather than the usual
/// `SPUStandardUpdaterController`. That controller starts the updater for
/// you and puts a modal alert on screen when starting fails -- and starting
/// *does* fail, by design, on any build whose `SUPublicEDKey` is still the
/// placeholder (see `publicKeyPlaceholder`). A daily dev build must not open
/// an error dialog at launch because a release key has not been generated
/// yet, so the failure is caught here and turned into a log line plus a
/// disabled menu item.
final class UpdateCoordinator: NSObject, NSMenuItemValidation {
    static let shared = UpdateCoordinator()

    /// The `SUPublicEDKey` value a build carries until Brady runs Sparkle's
    /// `generate_keys` once and pastes the real public key into
    /// `Sources/App/mac/Info.plist.in` (see docs/auto-update.md). Recognised
    /// explicitly so the updater is never started at all, rather than
    /// started and left to fail one silent update check at a time.
    private static let publicKeyPlaceholder = "REPLACE_WITH_SUPublicEDKey_FROM_generate_keys"

    /// `nil` once `start()` has successfully started the updater; stays
    /// `nil` when updates are switched off for this launch, which is what
    /// `validateMenuItem(_:)` reads to grey out "Check for Updates…".
    private var updater: SPUUpdater?

    private override init() {
        super.init()
    }

    /// Starts Sparkle, unless this launch is one that must never replace its
    /// own bundle. Safe to call more than once; only the first call does
    /// anything.
    func start() {
        guard updater == nil else { return }

        if let reason = Self.disabledReason() {
            NSLog("Browser: auto-update disabled for this launch (%@)", reason)
            return
        }

        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
        } catch {
            NSLog("Browser: Sparkle failed to start, auto-update is off: %@", error.localizedDescription)
            return
        }
        self.updater = updater
    }

    /// Why updates are off for this launch, or `nil` when they are on.
    ///
    /// Two cases, both of which would otherwise let Sparkle overwrite a
    /// bundle nobody wants overwritten:
    ///
    /// 1. A `--profiles-root` launch is a scratch/test instance -- what
    ///    `scripts/launch-scratch.sh` produces, and what every agent runs.
    ///    Those are throwaway copies under /tmp; an update check from one is
    ///    pure noise at best, and installing into the copy is worse.
    /// 2. A bundle sitting in the CMake output tree is the build's own
    ///    product. Sparkle replacing it would silently swap the code under
    ///    development for the last published release, and the next build
    ///    would overwrite the result anyway.
    private static func disabledReason() -> String? {
        if ProfilesRootResolver.explicitOverride(arguments: CommandLine.arguments) != nil {
            return "scratch launch: --profiles-root was passed"
        }

        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/build/Sources/App/") || bundlePath.contains("/build-release/Sources/App/") {
            return "running from the build output tree at \(bundlePath)"
        }

        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty, key != publicKeyPlaceholder else {
            return "no release EdDSA public key in Info.plist (SUPublicEDKey is unset or still the placeholder)"
        }

        return nil
    }

    /// Target/action for the "Check for Updates…" menu item -- a user-driven
    /// check, which shows Sparkle's own UI including a "you're up to date"
    /// result, unlike the scheduled background checks.
    @objc func checkForUpdates(_ sender: Any?) {
        updater?.checkForUpdates()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return updater?.canCheckForUpdates ?? false
    }
}
