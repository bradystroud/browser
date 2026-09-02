import AppKit

/// Remembers one auxiliary window's size and position across launches.
///
/// AppKit already offers this as `NSWindow.setFrameAutosaveName`, and this
/// deliberately does not use it: that writes through `UserDefaults.standard`,
/// which `--profiles-root` does not scope (see AppPreferencesStore) -- so an
/// agent resizing the History window in an "isolated" scratch launch would
/// move Brady's real one. Going through `AppPreferencesStore.current` keeps
/// a scratch launch's window geometry in that launch's own suite, exactly as
/// every other preference already is.
///
/// Hold one of these for as long as the window lives; it observes the
/// window's own move/resize notifications, so the owning controller needs no
/// delegate methods of its own (History, Downloads and the rest already use
/// theirs for other things).
final class WindowFrameMemory {
    private let key: String
    private weak var window: NSWindow?

    /// `name` identifies the window across launches, so it must be stable
    /// and distinct per window kind. Per-profile windows include the profile
    /// id: two profiles' History windows are two windows on screen at once
    /// and should not fight over one saved frame.
    init(window: NSWindow, name: String) {
        self.key = "WindowFrame.\(name)"
        self.window = window
        if let saved = AppPreferencesStore.current.string(forKey: key) {
            // Same reachability guard session restore uses -- a saved frame
            // outlives the display arrangement that produced it.
            window.setFrame(WindowManager.frameOnAVisibleScreen(NSRectFromString(saved)), display: false)
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(save), name: name, object: window)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func save() {
        guard let window, !window.isMiniaturized else { return }
        AppPreferencesStore.current.set(NSStringFromRect(window.frame), forKey: key)
    }
}
