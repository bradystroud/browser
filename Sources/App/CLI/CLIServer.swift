import AppKit
import Darwin

// CLIRequest/CLIResponse/CLIProfileInfo/CLITabInfo/CLISocketPath come from
// Packages/BrowserCLIProtocol/Sources/BrowserCLIProtocol -- compiled
// directly into this same target by Sources/App/CMakeLists.txt (see its
// BROWSER_CLI_PROTOCOL_SRCS), the same "one copy of the logic, two ways to
// build it" pattern as BlockList/BlockingSettings (BlockListCore) elsewhere
// in this file's sibling sources -- so no `import BrowserCLIProtocol` here.

/// Unix domain socket listener for the `browser` CLI (browser-82d) -- lets
/// an external process open URLs and query profiles/tabs on this running
/// instance without AppleScript/System Events UI automation, which this
/// project's own UI verification protocol (AGENTS.md) already bans for
/// agents -- this is the sanctioned alternative. One listener per running
/// instance, at a short hashed name in the per-user temp directory
/// (`CLISocketPath`) -- keyed by `--profiles-root` the same way
/// `profiles.json`/`session.json`/`routing.json` already are (see
/// `CommandLineArgs.sessionAndProfilesMetadataDirectory`), so a scratch test
/// instance's socket never collides with Brady's real running one.
///
/// Chose a raw Unix domain socket over Apple Events: Apple Events would
/// cover `open` (a plain `kAEGetURL`-alike) but not the query commands
/// (`profiles`/`tabs`), which need a real structured request/response, not a
/// fire-and-forget event -- a socket gives that for free with no scripting
/// dictionary/IDL to define. Framing is one newline-terminated JSON object
/// each way per connection (connect, write request, read one response line,
/// close) -- no persistent session, matching how infrequently and briefly a
/// CLI invocation talks to the app.
///
/// Only the user running the app may talk to it: the socket is mode 0600
/// inside a 0700 per-user directory, and every accepted connection's peer
/// uid is checked as well, since this socket can open arbitrary URLs and
/// read every open tab's address.
final class CLIServer {
    /// How long one client may take to send its request line. The accept
    /// queue is serial, so without a limit a client that connects and never
    /// finishes its line would stop every later CLI call from being served.
    private static let receiveTimeoutSeconds = 2

    /// A request is one small JSON object. Anything longer is not a real
    /// client and is refused rather than buffered without bound.
    private static let maximumRequestBytes = 64 * 1024

    static let shared = CLIServer()

    private var listenSocketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.browser.CLIServer")

    private init() {}

    /// Call once at launch, after RoutingCoordinator/ProfileManager/
    /// WindowManager are all ready to serve requests (see AppDelegate) --
    /// mirrors ContentBlockerCoordinator/ThreatListCoordinator's own
    /// "start once everything it needs is up" pattern. Failure to bind
    /// (e.g. a permissions problem on Application Support) is logged and
    /// otherwise swallowed -- CLI control is a convenience, not something
    /// worth failing the whole launch over.
    func start() {
        let directory = CommandLineArgs.sessionAndProfilesMetadataDirectory()
        let path = CLISocketPath.path(inDirectory: directory)

        // A stale socket file from a previous run that didn't exit cleanly
        // (crash, force-quit) would otherwise make bind() fail with
        // EADDRINUSE -- safe to remove unconditionally, since a Unix domain
        // socket file has no meaning once nothing is listening on it (unlike
        // e.g. a lock file, there's no state to lose by deleting it).
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("Browser: CLIServer socket() failed (errno %d) -- CLI control unavailable", errno)
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < sunPathSize else {
            NSLog("Browser: CLIServer socket path too long (%@) -- CLI control unavailable", path)
            close(fd)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: sunPathSize) { rebound in
                for (index, byte) in pathBytes.enumerated() { rebound[index] = byte }
                rebound[pathBytes.count] = 0
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { rawAddr in
            rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("Browser: CLIServer bind() failed (errno %d, path %@) -- CLI control unavailable", errno, path)
            close(fd)
            return
        }
        guard chmod(path, 0o600) == 0 else {
            NSLog("Browser: CLIServer chmod() failed (errno %d) -- CLI control unavailable", errno)
            close(fd)
            unlink(path)
            return
        }
        guard listen(fd, 8) == 0 else {
            NSLog("Browser: CLIServer listen() failed (errno %d) -- CLI control unavailable", errno)
            close(fd)
            return
        }

        listenSocketFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.resume()
        // Must be retained: an unretained DispatchSourceRead is deallocated
        // (and its monitoring silently cancelled -- no crash, no log) the
        // moment this function returns, which was confirmed by reproducing
        // exactly that hang against a scratch client/server before writing
        // this file. `acceptSource` existing as a stored property, not a
        // local, is the fix, not incidental.
        acceptSource = source
    }

    private func acceptConnection() {
        let clientFD = accept(listenSocketFD, nil, nil)
        guard clientFD >= 0 else { return }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            close(clientFD)
            return
        }
        var timeout = timeval(tv_sec: Self.receiveTimeoutSeconds, tv_usec: 0)
        setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // A client that disconnects before reading its response must not
        // take the app down with SIGPIPE.
        var noSigPipe: Int32 = 1
        setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        queue.async { [weak self] in
            self?.handleConnection(fd: clientFD)
        }
    }

    private func handleConnection(fd: Int32) {
        defer { close(fd) }
        guard let line = Self.readLine(fd: fd), let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(CLIRequest.self, from: data) else {
            Self.write(CLIResponse.failure("malformed request"), to: fd)
            return
        }

        // Every command below touches AppKit-affine state (WindowManager/
        // ProfileManager/RoutingCoordinator) -- hop to the main thread and
        // block this background queue until it produces a response, so the
        // client's one-shot read gets a real answer before this function's
        // `defer` closes its socket. Safe to block here specifically (never
        // on the main thread itself): this queue has no other work the main
        // thread could ever be waiting on.
        let response = DispatchQueue.main.sync { CLIServer.handle(request) }
        Self.write(response, to: fd)
    }

    private static func handle(_ request: CLIRequest) -> CLIResponse {
        switch request.command {
        case "open": return handleOpen(request)
        case "profiles": return handleProfiles()
        case "tabs": return handleTabs(request)
        case "window-new": return handleWindowNew(request)
        case "windows": return handleWindows(request)
        case "focus": return handleFocus(request)
        default: return .failure("unknown command: \(request.command)")
        }
    }

    /// `--profile` present -> opens there directly, bypassing routing rules
    /// entirely (an explicit override, same precedence as a routed link's
    /// own explicit-profile launch argument elsewhere in this app). Absent
    /// -> routes through RuleMatcher exactly like a real kAEGetURL-delivered
    /// link would, with `sourceBundleId: nil` (a CLI invocation has no
    /// attributable source app), so rules keyed on `sourceBundleIds` never
    /// match a CLI-issued open -- consistent with "no source" already
    /// meaning "don't match those rules" elsewhere (RuleMatcher.matches).
    ///
    /// `--little` opens a little window (LittleWindowController) instead of a
    /// tab, and `--new-window` a brand-new normal window. With neither, a
    /// routed open follows the matched rule's own `openIn`, but not the
    /// global "links from other apps" preference: a CLI call is an explicit
    /// request, not a link clicked somewhere else.
    private static func handleOpen(_ request: CLIRequest) -> CLIResponse {
        guard let url = request.args["url"], !url.isEmpty else {
            return .failure("open requires a url")
        }
        let forceLittleWindow = request.args["little"] == "true"
        let forceNewWindow = request.args["new-window"] == "true"
        if forceLittleWindow && forceNewWindow {
            return .failure("--little and --new-window can't be combined")
        }
        let forced: Placement? = forceLittleWindow ? .littleWindow : (forceNewWindow ? .newWindow : nil)

        if let profileName = request.args["profile"] {
            let profile = ProfileManager.shared.profileOrCreate(named: profileName)
            let placement = open(url, in: profile, placement: forced ?? .tab)
            return CLIResponse(ok: true, message: "Opened \(url) in profile '\(profile.name)' (explicit --profile, \(placement.phrase)).")
        }

        let (profile, resolution) = RoutingCoordinator.shared.resolveProfile(url: url, sourceBundleId: nil)
        let ruleOpenIn: RoutingRule.OpenIn?
        if case .matchedRule(let index) = resolution, RoutingRulesStore.shared.rules.indices.contains(index) {
            ruleOpenIn = RoutingRulesStore.shared.rules[index].action.openIn
        } else {
            ruleOpenIn = nil
        }
        let routed: Placement = ruleOpenIn == .littleWindow ? .littleWindow : .tab
        let placement = open(url, in: profile, placement: forced ?? routed)

        let matchNote: String
        switch resolution {
        case .matchedRule(let index): matchNote = "matched rule #\(index + 1)"
        case .activeWindow: matchNote = "no rule matched, used the frontmost window's profile"
        case .fallbackProfile: matchNote = "no rule matched and no window open, used the fallback profile"
        }
        return CLIResponse(ok: true, message: "Opened \(url) in profile '\(profile.name)' (\(matchNote), \(placement.phrase)).")
    }

    private enum Placement {
        case tab, newWindow, littleWindow

        /// For the response message.
        var phrase: String {
            switch self {
            case .tab: return "new tab"
            case .newWindow: return "new window"
            case .littleWindow: return "little window"
            }
        }
    }

    /// `.newWindow` deliberately bypasses `RoutingCoordinator.openURL`'s
    /// "reuse the frontmost window of this profile" step -- that reuse is
    /// exactly what the flag exists to opt out of -- but keeps everything
    /// upstream of it (profile resolution, routing rules) identical, so the
    /// only difference between placements is where the page lands. No
    /// explicit `NSApp.activate` on the new-window branch:
    /// `WindowManager.registerAndShow` already does it (respecting
    /// `--test-no-activate`), which is also why this doesn't just call
    /// `RoutingCoordinator.openURL` and then open a window.
    @discardableResult
    private static func open(_ url: String, in profile: Profile, placement: Placement) -> Placement {
        switch placement {
        case .tab:
            RoutingCoordinator.shared.openURL(url, in: profile)
        case .newWindow:
            WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
        case .littleWindow:
            LittleWindowController.open(url: url, profile: profile)
        }
        return placement
    }

    /// `window new` -- always a brand-new `WindowManager`-owned window, never
    /// a tab in an existing one, and never routed through `RuleMatcher`
    /// (there's no URL to match on in the common no-URL case, and an explicit
    /// "open a window in profile X" request has already decided the profile).
    ///
    /// With no URL, opens `about:blank` -- `Tab`'s sentinel for the internal
    /// start page -- rather than `WindowManager.openNewWindow`'s own
    /// `initialURL` default, which is still the M1-era `https://example.com`
    /// placeholder that ⌘N inherits. A CLI/Raycast "new empty window" should
    /// land on the start page, not navigate to a real external site.
    private static func handleWindowNew(_ request: CLIRequest) -> CLIResponse {
        let url = request.args["url"].flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
        let profile = request.args["profile"].map { ProfileManager.shared.profileOrCreate(named: $0) }
            ?? ProfileManager.shared.fallbackProfile
        WindowManager.shared.openNewWindow(profile: profile, initialURL: url)
        let target = url == "about:blank" ? "the start page" : url
        return CLIResponse(ok: true, message: "Opened a new window in profile '\(profile.name)' showing \(target).")
    }

    /// `focus` -- bring a profile's frontmost window to the front, opening
    /// one if that profile has none. "Take me to this profile" as a single
    /// operation (browser-dpf).
    ///
    /// Reuse-or-create rather than a strict focus-only command, for two
    /// reasons. It matches `open`'s own established semantics (which already
    /// reuses the profile's frontmost window and creates one when there
    /// isn't one), and doing it in one round trip removes the race a
    /// caller-side "focus, and if that fails open a new window" pair would
    /// have -- the window could close in between, or two rapid invocations
    /// could each see "none" and open two windows.
    ///
    /// Frontmost is resolved by z-order, not key status
    /// (WindowManager.frontmostWindowController), which is what makes this
    /// right even when the currently-key window belongs to another profile
    /// -- the usual case when this is invoked from Raycast.
    private static func handleFocus(_ request: CLIRequest) -> CLIResponse {
        let profile = request.args["profile"].map { ProfileManager.shared.profileOrCreate(named: $0) }
            ?? ProfileManager.shared.fallbackProfile

        guard let controller = WindowManager.shared.frontmostWindowController(forProfileId: profile.id) else {
            WindowManager.shared.openNewWindow(profile: profile, initialURL: "about:blank")
            return CLIResponse(
                ok: true,
                message: "No window was open for profile '\(profile.name)' — opened a new one."
            )
        }

        // Activating the app is the half that actually matters here: this
        // arrives while some *other* app (Raycast) is frontmost, so ordering
        // the window front without activating would raise it within a hidden
        // app and look like nothing happened. Skipped under
        // --test-no-activate for the same reason WindowManager skips it --
        // stealing real keyboard focus is exactly what that flag prevents.
        if !CommandLineArgs.testNoActivate() {
            AppActivation.activate()
        }
        controller.window?.makeKeyAndOrderFront(nil)
        return CLIResponse(ok: true, message: "Focused profile '\(profile.name)'.")
    }

    /// `windows` -- one row per open window. `windowIndex` is numbered over
    /// the windows actually listed, so a `--profile`-filtered listing starts
    /// at 0 -- deliberately identical to `handleTabs`' own numbering, so the
    /// two commands never disagree about what "window 1" means for the same
    /// filter.
    ///
    /// Private windows are never listed, here or in `tabs`: what a private
    /// window shows must not leave the window, and this socket's output
    /// ends up in shell history, scripts and Raycast.
    private static func handleWindows(_ request: CLIRequest) -> CLIResponse {
        let profileNameFilter = request.args["profile"]
        var windowInfos: [CLIWindowInfo] = []
        var windowIndex = 0
        for controller in WindowManager.shared.windowControllers where !controller.isPrivate {
            if let profileNameFilter, controller.profile.name != profileNameFilter { continue }
            let activeTab = controller.activeTabIndex.flatMap { index in
                controller.tabs.indices.contains(index) ? controller.tabs[index] : nil
            }
            // Same "" -> about:blank sentinel translation as handleTabs.
            let activeURL = activeTab.map { $0.urlString.isEmpty ? "about:blank" : $0.urlString } ?? ""
            windowInfos.append(CLIWindowInfo(
                profileName: controller.profile.name,
                profileId: controller.profile.id,
                windowIndex: windowIndex,
                tabCount: controller.tabs.count,
                isPrivate: controller.isPrivate,
                activeTabTitle: activeTab?.title ?? "",
                activeTabURL: activeURL
            ))
            windowIndex += 1
        }
        return CLIResponse(ok: true, message: "\(windowInfos.count) window(s)", windows: windowInfos)
    }

    private static func handleProfiles() -> CLIResponse {
        let profiles = ProfileManager.shared.profiles.map { profile -> CLIProfileInfo in
            let windowCount = WindowManager.shared.windowControllers.filter { !$0.isPrivate && $0.profile.id == profile.id }.count
            return CLIProfileInfo(id: profile.id, name: profile.name, colorHex: profile.colorHex, windowCount: windowCount)
        }
        return CLIResponse(ok: true, message: "\(profiles.count) profile(s)", profiles: profiles)
    }

    /// `windowIndex` is the position of that window among the (optionally
    /// profile-filtered) windows being listed, not a persistent identifier
    /// -- purely for a human or script to tell two of the same profile's
    /// windows apart in one listing, same caveat as `CLITabInfo`'s own doc
    /// comment.
    private static func handleTabs(_ request: CLIRequest) -> CLIResponse {
        let profileNameFilter = request.args["profile"]
        var tabInfos: [CLITabInfo] = []
        var windowIndex = 0
        for controller in WindowManager.shared.windowControllers where !controller.isPrivate {
            if let profileNameFilter, controller.profile.name != profileNameFilter { continue }
            for (tabIndex, tab) in controller.tabs.enumerated() {
                // Tab.urlString is "" while showing the internal start page
                // (see Tab.swift) -- "about:blank" is that sentinel's own
                // input-side spelling elsewhere in this app (CommandLineArgs.
                // initialURL), so it's what's shown here too rather than a
                // blank/confusing empty string.
                let url = tab.urlString.isEmpty ? "about:blank" : tab.urlString
                tabInfos.append(CLITabInfo(
                    profileName: controller.profile.name,
                    windowIndex: windowIndex,
                    tabIndex: tabIndex,
                    isActive: tabIndex == controller.activeTabIndex,
                    title: tab.title,
                    url: url,
                    isAsleep: tab.isAsleep
                ))
            }
            windowIndex += 1
        }
        return CLIResponse(ok: true, message: "\(tabInfos.count) tab(s)", tabs: tabInfos)
    }

    private static func readLine(fd: Int32) -> String? {
        var buffer: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { break }
            buffer.append(byte)
            if buffer.count > maximumRequestBytes { return nil }
        }
        guard !buffer.isEmpty else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    private static func write(_ response: CLIResponse, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            _ = Darwin.write(fd, raw.baseAddress, raw.count)
        }
    }
}
