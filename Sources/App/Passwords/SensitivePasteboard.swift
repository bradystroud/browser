import AppKit

/// Puts a saved secret (a password, a card number) on the clipboard the way
/// a password manager should: on this Mac only, never to Universal
/// Clipboard; marked concealed and transient, which is what clipboard
/// managers go by (nspasteboard.org) to keep it out of their history; and
/// taken off again after `clearDelay` of wall-clock time, or when the app
/// quits first, unless something else has been copied since.
enum SensitivePasteboard {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let defaultClearDelay: TimeInterval = 90

    /// The last secret copied and the change count it left the pasteboard
    /// at, until it has been cleared or overwritten.
    private static var pending: (pasteboard: NSPasteboard, changeCount: Int)?
    private static var terminationObserver: NSObjectProtocol?

    static func copy(_ secret: String, to pasteboard: NSPasteboard = .general, clearAfter clearDelay: TimeInterval = defaultClearDelay) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: transientType)
        let copied = pasteboard.changeCount
        pending = (pasteboard, copied)
        observeTermination()
        // Wall-clock, so time the Mac spends asleep counts towards the delay.
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + clearDelay) {
            clearIfUnchanged(pasteboard, changeCount: copied)
        }
    }

    /// Clears the last copied secret now if nothing has been copied over it.
    static func clearPendingIfUnchanged() {
        guard let pending else { return }
        clearIfUnchanged(pending.pasteboard, changeCount: pending.changeCount)
    }

    private static func clearIfUnchanged(_ pasteboard: NSPasteboard, changeCount: Int) {
        if pasteboard.changeCount == changeCount {
            pasteboard.clearContents()
        }
        if let pending, pending.pasteboard === pasteboard, pending.changeCount == changeCount {
            self.pending = nil
        }
    }

    private static func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            clearPendingIfUnchanged()
        }
    }
}
