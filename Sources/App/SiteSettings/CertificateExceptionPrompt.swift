import AppKit
import SecurityInterface

/// Asks the user to confirm a certificate exception, as a sheet on the tab's
/// window. The only way an exception is ever added: the error page's
/// "Visit Anyway…" link and Site Settings both come here, and the page
/// itself can at most open this question, never answer it.
enum CertificateExceptionPrompt {
    static func present(for tab: Tab, host: String) {
        guard tab.usesCertificateExceptions,
              let failure = tab.refusedCertificates[host],
              let window = tab.hostView.window, window.isVisible,
              window.attachedSheet == nil
        else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Visit \u{201C}\(host)\u{201D} anyway?"
        let scope = tab.isPrivate
            ? "in this private window until you close it"
            : "in the \u{201C}\(tab.profileName)\u{201D} profile"
        alert.informativeText = """
        The certificate for this site is not valid. Someone could be pretending to be \(host).

        If you continue, Browser trusts this exact certificate for \(host) \(scope). If the certificate changes, you are asked again. Do this only for a site you control, such as a device on your own network.

        You can remove the exception in Settings for This Website.
        """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Visit Anyway")
        if failure.serverTrust != nil {
            alert.addButton(withTitle: "Show Certificate\u{2026}")
        }
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[1].hasDestructiveAction = true

        alert.beginSheetModal(for: window) { [weak tab] response in
            guard let tab else { return }
            switch response {
            case .alertSecondButtonReturn:
                tab.trustRefusedCertificate(host: host)
            case .alertThirdButtonReturn:
                guard let trust = failure.serverTrust else { return }
                // After the alert's own sheet has gone.
                DispatchQueue.main.async {
                    guard window.attachedSheet == nil else { return }
                    SFCertificatePanel.shared().beginSheet(
                        for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust, showGroup: true)
                }
            default:
                break
            }
        }
    }
}
