import AppKit
// IsSecureEventInputEnabled() -- see `secureEventInput` below for why a
// browser, uniquely among the apps on a Mac, is a plausible source of a stuck
// secure-input state.
import Carbon.HIToolbox

/// Structured diagnostics for "another app activates but keyboard focus stays
/// in the browser" (browser-2ji).
///
/// The reported symptom is that summoning Raycast over a frontmost browser
/// window shows Raycast but the first keystrokes don't reach it until it's
/// clicked -- and that no other app on the machine behaves this way. Nothing
/// in this app's own source explains it: every `NSApp.activate` call site is
/// user-initiated, the always-on `NSEvent` monitors are local-only, and the
/// panels that install global monitors are mouse-only and short-lived.
///
/// That leaves several mutually exclusive stories, and the reproduction is a
/// global hotkey no agent here is allowed to press (see AGENTS.md's UI
/// verification protocol), so this records enough per event to tell them
/// apart from a single reproduction:
///
///  1. **We never deactivate.** `appDidResignActive` is absent, or is
///     followed immediately by `appDidBecomeActive` and/or
///     `appRequestedActivation`. Fault is in our shell -- something
///     re-activates us out from under Raycast.
///  2. **We deactivate, but keys still arrive here.** `appDidResignActive`
///     is present *and* `keyEventWhileAppInactive` records follow. The
///     window server is still routing keystrokes to this process; look at
///     `keyWindow`/`firstResponder` in the surrounding snapshots.
///  3. **We deactivate cleanly and no keys arrive.** `appDidResignActive` is
///     present, `frontmostApp` is Raycast, no `keyEventWhileAppInactive`
///     records. Then the keystrokes are being swallowed *before* app
///     dispatch -- and the field to read is `secureEventInput`, which is the
///     one system-wide keyboard state a Chromium-hosting app can leave stuck
///     and which nothing else on the machine would touch.
///
/// Deliberately records no typed characters and no key codes -- only that a
/// key event arrived, and its modifier flags. A diagnostic for a keyboard bug
/// must never become a keylogger, and the counts and timing are what the
/// three stories above are told apart by.
///
/// Off unless switched on, and switchable on *without a relaunch* -- same
/// marker-file pattern, and the same reasoning, as `TabDragDiagnostics`: the
/// person who has to turn this on is running an installed /Applications build
/// he can't easily pass launch arguments to.
enum FocusDiagnostics {
    /// `touch` this to start recording; delete it to stop. Sits next to
    /// session.json/profiles.json, so it's scoped by `--profiles-root` the
    /// same way they are and an agent's scratch instance can never write into
    /// the real one's log.
    private static let markerName = "focus-diagnostics.on"
    private static let logName = "focus-diagnostics.json"

    /// One summon-Raycast-and-type reproduction is a handful of records; this
    /// bounds an afternoon of app switching. Oldest dropped first -- the
    /// interesting attempt is always the most recent.
    private static let maxRecords = 600

    private static var records: [[String: Any]] = []
    private static var flushScheduled = false
    private static var isInstalled = false
    private static var keyMonitor: Any?

    private static var directory: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path
        return ProfilesRootResolver.sessionAndProfilesMetadataDirectory(
            arguments: CommandLine.arguments, appSupportDirectory: appSupport
        )
    }

    /// Stat'd per call rather than cached -- see the type's own doc comment.
    /// `--focus-diagnostics` is the equivalent for a launch we do control.
    static var isEnabled: Bool {
        if isForcedOnByArgument { return true }
        return FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(markerName))
    }

    private static let isForcedOnByArgument = CommandLine.arguments.contains("--focus-diagnostics")

    static var logPath: String {
        (directory as NSString).appendingPathComponent(logName)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    // MARK: - Installation

    /// Installs every observer this needs, unconditionally and once, at
    /// launch. The observers are always live but `record` no-ops while the
    /// marker file is absent -- that's what makes turning diagnostics on
    /// mid-session, without a relaunch, possible.
    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            record("appDidResignActive", snapshot())
            // The interesting state is not the instant AppKit posts this --
            // it's a beat later, once the other app's window is up and the
            // user has started typing into it. Three samples bracket a
            // realistic "summon Raycast, type" gesture.
            for delay in [0.25, 1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard !NSApp.isActive else { return }
                    record("whileInactive", snapshot(["afterResignSeconds": delay]))
                }
            }
        }
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            record("appDidBecomeActive", snapshot())
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
            record("windowDidResignKey", windowSnapshot(note.object as? NSWindow))
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            record("windowDidBecomeKey", windowSnapshot(note.object as? NSWindow))
        }
        // Posted by -[BRWApplication activateIgnoringOtherApps:]. Answers the
        // one question the notifications above can't: when this app comes back
        // to the front, did *it* ask to? (CEF launches only -- under
        // `--engine webkit` NSApp is a stock NSApplication with no such
        // override, so this record simply never appears.)
        center.addObserver(
            forName: Notification.Name("AppActivationRequestedNotification"), object: nil, queue: .main
        ) { note in
            // The stack comes over in userInfo rather than being read here:
            // this block is delivered through the main queue, by which point
            // the frames that asked for the activation are long gone.
            let stack = (note.userInfo?["callStack"] as? [String])?.prefix(14).map { $0 } ?? []
            record("appRequestedActivation", snapshot(["callStack": stack]))
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            record("workspaceDidActivateApp", [
                "bundleId": app?.bundleIdentifier ?? "nil",
                "name": app?.localizedName ?? "nil",
                "isUs": app?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                "secureEventInput": IsSecureEventInputEnabled()
            ])
        }

        // A *local* monitor sees events dispatched into this process's own
        // event stream. If one fires while `NSApp.isActive` is false, the
        // window server is still routing the user's keystrokes here rather
        // than to the app they think they're typing into -- which is exactly
        // story 2 in the type's doc comment, and cannot be observed any other
        // way from inside this process.
        //
        // Nothing is recorded while the app is active: that's the normal case,
        // and skipping it keeps both the log and the privacy surface small.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if !NSApp.isActive {
                record("keyEventWhileAppInactive", snapshot([
                    "eventType": event.type == .keyDown ? "keyDown" : "flagsChanged",
                    // Modifier flags only -- never characters or key codes.
                    "modifiers": event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
                    "isARepeat": event.type == .keyDown && event.isARepeat
                ]))
            }
            return event
        }
    }

    // MARK: - Snapshots

    /// The state that distinguishes the three stories, sampled at one instant.
    private static func snapshot(_ extra: [String: Any] = [:]) -> [String: Any] {
        var fields = extra
        fields["appActive"] = NSApp.isActive
        fields["appHidden"] = NSApp.isHidden
        // Enabled by AppKit whenever a secure text field holds focus, and by
        // Chromium whenever a page's password field does -- in *this* process,
        // since the render widget's NSView lives in the browser process. It is
        // reference-counted per process and system-wide in effect: while it is
        // on, keyboard event taps are shut off and input methods are bypassed,
        // which is the shape of "Raycast is up but won't take my typing". It
        // is also the only entry here that would explain "no other app on my
        // Mac has this issue" without any bug in our own AppKit code.
        fields["secureEventInput"] = IsSecureEventInputEnabled()
        fields["frontmostApp"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        fields["menuBarOwningApp"] = NSWorkspace.shared.menuBarOwningApplication?.bundleIdentifier ?? "nil"
        fields["appKeyWindow"] = NSApp.keyWindow.map { describe($0) } ?? "nil"
        fields["appMainWindow"] = NSApp.mainWindow.map { describe($0) } ?? "nil"
        fields["hasTextInputContext"] = NSTextInputContext.current != nil
        fields["windows"] = NSApp.windows
            .filter { $0.isVisible }
            .prefix(12)
            .map { windowSnapshot($0) }
        return fields
    }

    private static func windowSnapshot(_ window: NSWindow?) -> [String: Any] {
        guard let window else { return ["window": "nil"] }
        let responder = window.firstResponder
        var fields: [String: Any] = [
            "window": describe(window),
            "isKey": window.isKeyWindow,
            "isMain": window.isMainWindow,
            "level": window.level.rawValue,
            "firstResponder": responder.map { String(describing: type(of: $0)) } ?? "nil",
            "firstResponderChain": responderChain(from: responder)
        ]
        if let hosting = webContentHost(for: responder, in: window) {
            fields["firstResponderInsideWebContent"] = true
            fields["webContentTabIndex"] = hosting
        } else {
            fields["firstResponderInsideWebContent"] = false
        }
        return fields
    }

    /// Which tab's engine host view (if any) the window's first responder sits
    /// inside. Engine-agnostic on purpose: `Tab.hostView` is the Swift-owned
    /// NSView the engine parents its own rendering view into, for CEF and
    /// WebKit alike, so "is the web content holding keyboard focus?" is
    /// answered without naming either engine.
    private static func webContentHost(for responder: NSResponder?, in window: NSWindow) -> Int? {
        guard let view = responder as? NSView,
              let controller = window.windowController as? BrowserWindowController else { return nil }
        for (index, tab) in controller.tabs.enumerated() {
            var current: NSView? = view
            while let candidate = current {
                if candidate === tab.hostView { return index }
                current = candidate.superview
            }
        }
        return nil
    }

    private static func responderChain(from responder: NSResponder?) -> [String] {
        var chain: [String] = []
        var current = responder
        while let candidate = current, chain.count < 8 {
            chain.append(String(describing: type(of: candidate)))
            current = candidate.nextResponder
        }
        return chain
    }

    private static func describe(_ window: NSWindow) -> String {
        "\(type(of: window))(\(window.windowNumber))"
    }

    // MARK: - Recording

    static func record(_ stage: String, _ fields: [String: Any] = [:]) {
        guard isEnabled else { return }
        var entry: [String: Any] = fields
        entry["stage"] = stage
        entry["t"] = timestampFormatter.string(from: Date())
        records.append(entry)
        if records.count > maxRecords {
            records.removeFirst(records.count - maxRecords)
        }
        scheduleFlush()
    }

    /// Coalesced, but short -- the whole point is that the file is already on
    /// disk when the user gives up on typing into the other app and comes back
    /// here, and that it survives whatever happens next.
    private static func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            flushScheduled = false
            flush()
        }
    }

    private static func flush() {
        guard let data = try? JSONSerialization.data(
            withJSONObject: records, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
    }
}
