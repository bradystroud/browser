import AppKit

/// Recognizes the ⌥⇧-click that asks for a link peek.
///
/// Neither engine reports a link click's modifiers in a form that can tell
/// ⌥⇧ from ⇧: both hand the app a plain "new window" request, CEF's after a
/// renderer round trip. So the gesture is recorded from the mouse-down event
/// itself, whose modifiers are exact, and a new-window request from the same
/// window shortly afterwards is what claims it. Reading the live keyboard
/// state when the request arrives would race the user letting go of the keys.
struct LinkPeekGesture {
    static let modifiers: NSEvent.ModifierFlags = [.option, .shift]

    /// How long after the mouse-down a new-window request still counts as
    /// the peek's. A click's request arrives within milliseconds of the
    /// mouse-up; the margin covers a slow press, not a slow page.
    static let lifetime: TimeInterval = 1.5

    private(set) var pending: (windowNumber: Int, time: TimeInterval)?

    static func isPeekClick(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .option, .shift]) == modifiers
    }

    /// Every left mouse-down replaces the last one, so an ordinary click in
    /// between cancels a peek gesture that never produced a request.
    mutating func recordMouseDown(windowNumber: Int, modifiers: NSEvent.ModifierFlags, time: TimeInterval) {
        pending = Self.isPeekClick(modifiers) ? (windowNumber, time) : nil
    }

    /// True at most once per gesture, for a request from the window it
    /// happened in.
    mutating func consume(windowNumber: Int, now: TimeInterval) -> Bool {
        guard let pending, pending.windowNumber == windowNumber else { return false }
        self.pending = nil
        let age = now - pending.time
        return age >= 0 && age <= Self.lifetime
    }
}

/// The app-wide mouse-down watcher feeding LinkPeekGesture: one local
/// monitor for the whole app, installed with the first window.
final class LinkPeekGestureMonitor {
    static let shared = LinkPeekGestureMonitor()

    private var gesture = LinkPeekGesture()
    private var monitor: Any?

    private init() {}

    func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.gesture.recordMouseDown(
                windowNumber: event.windowNumber, modifiers: event.modifierFlags, time: event.timestamp)
            return event
        }
    }

    func consume(windowNumber: Int) -> Bool {
        gesture.consume(windowNumber: windowNumber, now: ProcessInfo.processInfo.systemUptime)
    }
}
