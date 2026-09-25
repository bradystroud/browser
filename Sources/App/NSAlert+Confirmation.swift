import AppKit

extension NSAlert {
    /// A warning that asks before an action that deletes the user's data.
    /// The first button performs the action and is marked destructive, so
    /// AppKit can style it as one. The second button cancels.
    static func destructiveConfirmation(
        message: String,
        informativeText: String,
        confirmTitle: String,
        cancelTitle: String = "Cancel"
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = informativeText
        alert.addButton(withTitle: confirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: cancelTitle)
        return alert
    }

    /// Runs `destructiveConfirmation` app-modally and returns true only if
    /// the user chose the destructive button.
    static func confirmDestructive(message: String, informativeText: String, confirmTitle: String) -> Bool {
        destructiveConfirmation(message: message, informativeText: informativeText, confirmTitle: confirmTitle)
            .runModal() == .alertFirstButtonReturn
    }
}
