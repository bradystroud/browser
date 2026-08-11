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
/// The first capture settled the shape of it, and it was not any of the three
/// app-level stories this file was originally built around. **Raycast never
/// deactivates this app at all.** It is an accessory (`LSUIElement`) process
/// showing a non-activating panel, so it takes the *key window* without ever
/// becoming the frontmost application: `NSApp.isActive` stays true, no
/// `didResignActive` is posted, and `NSWorkspace` never reports it. The entire
/// trace it leaves in this process is a lone `NSWindow` key transition.
///
/// That was confirmed rather than assumed, by building a throwaway accessory
/// app with exactly that window style and pointing it at a real instance of
/// this browser: the panel took key status, kept it for the full six seconds
/// it was up, and all this browser recorded was one bare `windowDidResignKey`.
///
/// Which makes the diagnosis a question about key-window transitions, not
/// activation:
///
///  1. **We take the key window straight back.** A `windowDidBecomeKey`
///     carrying `reclaimedKeyAfterSeconds` -- our window regaining key status
///     within milliseconds of losing it, snatching keyboard focus from the
///     panel that just took it. Its `callStack` names whoever asked. Brady's
///     first capture holds three of these at 0-10 ms, against seven benign
///     summons that held key for 1.6-7 s.
///  2. **We never lose it.** The panel appears and no key transition is
///     recorded at all. Then focus never moved and the fault is upstream of
///     AppKit's window server handoff.
///  3. **We lose it cleanly but keys still arrive here.** A key transition
///     followed by `suspiciousKeyEvent` records whose `destinationWindow` is
///     a `BrowserWindow`. That is the user's typing landing in the browser,
///     proven outright.
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

    /// When each window last resigned key status. Drives both the
    /// "took key back within milliseconds" detector and the key-event
    /// monitor's notion of a suspicious moment.
    private static var lastKeyResign: [ObjectIdentifier: Date] = [:]

    private static let ourPid = ProcessInfo.processInfo.processIdentifier

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

        // `queue: nil` throughout, deliberately -- these observers run
        // synchronously on the thread that posted, which is what makes
        // `Thread.callStackSymbols` inside them worth reading: AppKit posts
        // each of these from inside the call that caused it, so the stack
        // names whoever asked. Handing the block to `.main` instead (as the
        // first version of this file did) defers it to a later run-loop turn,
        // by which point the frames that matter have returned -- and that cost
        // us the answer once already.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in
            record("appDidResignActive", snapshot(["callStack": callStack()]))
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
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            record("appDidBecomeActive", snapshot(["callStack": callStack()]))
        }
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: nil) { note in
            let window = note.object as? NSWindow
            if let window { lastKeyResign[ObjectIdentifier(window)] = Date() }
            record("windowDidResignKey", windowSnapshot(window, ["callStack": callStack()]))
            // A window resigning key with no accompanying app-level
            // deactivation is the *only* trace an accessory app's
            // non-activating panel leaves in this process -- confirmed by
            // reproducing it with a purpose-built probe app. Everything
            // hanging off `didResignActive` above stays silent through it, so
            // it gets its own sampling here or the whole episode is invisible.
            for delay in [0.25, 1.0, 3.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard NSApp.keyWindow == nil else { return }
                    record("whileNoKeyWindow", snapshot(["afterResignKeySeconds": delay]))
                }
            }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: nil) { note in
            let window = note.object as? NSWindow
            var extra: [String: Any] = ["callStack": callStack()]
            // The pathological case, and the reason for the synchronous stack
            // above: a window that takes key status back within a few
            // milliseconds of losing it has snatched keyboard focus from
            // whatever just took it. Brady's first capture contains three of
            // these at 0-10 ms, against seven benign summons in the 1.6-7 s
            // range, and they are the failed Raycast summons.
            if let window,
               let resigned = lastKeyResign[ObjectIdentifier(window)],
               Date().timeIntervalSince(resigned) < 0.3 {
                extra["reclaimedKeyAfterSeconds"] = Date().timeIntervalSince(resigned)
            }
            record("windowDidBecomeKey", windowSnapshot(window, extra))
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
                "pid": Int(app?.processIdentifier ?? -1),
                "isUs": app?.processIdentifier == ourPid,
                "secureEventInput": IsSecureEventInputEnabled()
            ])
        }

        // A *local* monitor sees events dispatched into this process's own
        // event stream, and a key event arriving here when it shouldn't is the
        // most direct evidence available that the user's typing is landing in
        // the browser rather than in the app they're looking at.
        //
        // The trigger deliberately is NOT `!NSApp.isActive`, which is what the
        // first version of this file used and which recorded precisely nothing
        // through ten real reproductions: an accessory app's non-activating
        // panel takes the key window without this app ever deactivating, so
        // `NSApp.isActive` stays true for the whole episode. What actually
        // marks the episode is a key window transition, so a key event counts
        // as suspicious if either the app is inactive *or* one of our windows
        // lost key status within the last few seconds -- which covers both the
        // "we never deactivated" and "we took key straight back" shapes.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let recentlyLostKey = lastKeyResign.values.contains { Date().timeIntervalSince($0) < 5 }
            if !NSApp.isActive || recentlyLostKey {
                record("suspiciousKeyEvent", snapshot([
                    "eventType": event.type == .keyDown ? "keyDown" : "flagsChanged",
                    // Modifier flags only -- never characters or key codes.
                    "modifiers": event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue,
                    "isARepeat": event.type == .keyDown && event.isARepeat,
                    "reason": NSApp.isActive ? "windowRecentlyLostKey" : "appInactive",
                    // Where the keystroke is about to be delivered. If this
                    // names a BrowserWindow while the user believes they are
                    // typing into a launcher, the bug is proven outright.
                    "destinationWindow": NSApp.keyWindow.map { describe($0) } ?? "nil"
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
        // Recorded by pid as well as bundle id, and never by bundle id alone.
        // Agents run scratch instances of this very app, which share its
        // bundle identifier exactly -- so a plain `frontmostApp` of
        // "dev.stroud.browser" cannot distinguish "we are still frontmost"
        // (the signature of another app's non-activating panel taking focus)
        // from "a different copy of us took the front" (an ordinary app
        // switch). Reading the first capture without this field produced
        // exactly that misdiagnosis, on four records out of fourteen.
        let frontmost = NSWorkspace.shared.frontmostApplication
        fields["frontmostApp"] = frontmost?.bundleIdentifier ?? "nil"
        fields["frontmostPid"] = Int(frontmost?.processIdentifier ?? -1)
        fields["frontmostIsUs"] = frontmost?.processIdentifier == ourPid
        fields["menuBarOwningApp"] = NSWorkspace.shared.menuBarOwningApplication?.bundleIdentifier ?? "nil"
        fields["ourPid"] = Int(ourPid)
        fields["appKeyWindow"] = NSApp.keyWindow.map { describe($0) } ?? "nil"
        fields["appMainWindow"] = NSApp.mainWindow.map { describe($0) } ?? "nil"
        fields["hasTextInputContext"] = NSTextInputContext.current != nil
        fields["windows"] = NSApp.windows
            .filter { $0.isVisible }
            .prefix(12)
            .map { windowSnapshot($0) }
        return fields
    }

    /// Frames worth keeping from a synchronously-delivered notification: the
    /// AppKit/CEF path that caused it. Trimmed because the tail is always the
    /// same run-loop boilerplate, and the answer is always near the top.
    private static func callStack() -> [String] {
        Thread.callStackSymbols.prefix(18).map { $0 }
    }

    private static func windowSnapshot(_ window: NSWindow?, _ extra: [String: Any] = [:]) -> [String: Any] {
        guard let window else { return ["window": "nil"] }
        let responder = window.firstResponder
        var fields: [String: Any] = extra
        fields["window"] = describe(window)
        fields["isKey"] = window.isKeyWindow
        fields["isMain"] = window.isMainWindow
        fields["level"] = window.level.rawValue
        fields["firstResponder"] = responder.map { String(describing: type(of: $0)) } ?? "nil"
        fields["firstResponderChain"] = responderChain(from: responder)
        // The window that took keyboard focus instead of this one, if any.
        // An accessory app's non-activating panel is invisible to
        // NSWorkspace, so this is the only handle on "who took it".
        fields["appKeyWindowNow"] = NSApp.keyWindow.map { describe($0) } ?? "nil"
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
