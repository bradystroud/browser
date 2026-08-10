import AppKit

/// Keeps a floating panel glued to an anchor window **without**
/// `NSWindow.addChildWindow(_:ordered:)`.
///
/// ## Why this exists (browser-5kq.10)
///
/// `addChildWindow(_:ordered:)` doesn't just parent a window: it makes AppKit
/// rebuild the anchor window's entire *ordering group*
/// (`NSPerformVisuallyAtomicChange` -> `_rebuildOrderingGroup:` ->
/// `_NSWindowWalkOrderingGroupInternal`), walking and re-ordering every window
/// already in that group. In this app that group contains CEF's own windows
/// and, when the omnibox has focus, an out-of-process `NSRemoteView` hosting
/// macOS's own completion-list service. That remote view asserts when the
/// ordering walk notifies it about a window that isn't its own container, and
/// an uncaught `NSInternalInconsistencyException` kills the whole browser:
///
/// ```
/// *** Terminating app due to uncaught exception 'NSInternalInconsistencyException',
/// reason: 'assertion failed: '<NSRemoteView: 0x… com.apple.SafariPlatformSupport.Helper
/// SPCompletionListServiceViewController> notified of <Browser…StartPanel: 0x…>
/// but expected <SPRoundedWindow: 0x…>' in -[NSRemoteView containingWindowWillOrderOnScreen:]
/// ```
///
/// That crash took Brady's real browser down on the first omnibox click after
/// the start panel shipped. **Do not add a child window to a browser window in
/// this app.** A plain `orderFront(_:)` of a standalone panel doesn't rebuild
/// any ordering group (it's the path the shortcuts overlay, Visual Look Up
/// panel, and every secondary window here already take), so this class trades
/// the child-window relationship for explicit tracking of the four things that
/// relationship used to provide for free:
///
/// - the panel follows the anchor window when it moves,
/// - it repositions when the anchor resizes,
/// - it goes away when the anchor is miniaturized, closed, or stops being key,
/// - it goes away when the app itself is deactivated.
///
/// Z-order above the anchor comes from the panel's own window level instead
/// (`.popUpMenu`), not from parenthood.
final class AnchoredPanelTracker {
    private var observers: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - onReposition: recompute and apply the panel's frame -- called on
    ///     anchor move/resize.
    ///   - onDismiss: tear the panel down entirely -- called when the anchor
    ///     window or the app is no longer in a state where a panel attached to
    ///     it makes sense.
    init(
        anchorWindow: NSWindow,
        onReposition: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            observers.append(center.addObserver(forName: name, object: anchorWindow, queue: .main) { _ in
                onReposition()
            })
        }
        for name in [
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification,
            NSWindow.didResignKeyNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: anchorWindow, queue: .main) { _ in
                onDismiss()
            })
        }
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            onDismiss()
        })
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    deinit {
        stop()
    }
}
