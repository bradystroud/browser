import AppKit
import LocalAuthentication

/// The Touch-ID-gated "Reveal…" flow shared by the Passwords and Cards
/// panes. The stores behind them (PasswordStore.password, CardStore.
/// cardNumber) perform no check of their own, so this gate is the only thing
/// standing between a saved secret and the screen.
enum SecretReveal {
    /// Runs a fresh LocalAuthentication check (Touch ID, falling back to the
    /// account password, as `.deviceOwnerAuthentication` does) and calls
    /// `onSuccess` on the main queue only if it passes. `noun` names what is
    /// being revealed in the alert shown when no check is possible.
    static func authenticate(toReveal noun: String, reason: String, onSuccess: @escaping () -> Void) {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &evaluationError) else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Can't Verify Identity"
            alert.informativeText = "Touch ID or your account password isn't available for verification on this Mac, so this \(noun) can't be revealed."
            alert.runModal()
            return
        }

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                guard success else { return }
                onSuccess()
            }
        }
    }

    /// Shows an already-authenticated secret, with a button that copies it.
    static func present(_ secret: String, title: String, copyButtonTitle: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = secret
        alert.addButton(withTitle: copyButtonTitle)
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            SensitivePasteboard.copy(secret)
        }
    }
}
