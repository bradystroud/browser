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
/// instance, at `<sessionAndProfilesMetadataDirectory>/cli.sock`
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
final class CLIServer {
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
    private static func handleOpen(_ request: CLIRequest) -> CLIResponse {
        guard let url = request.args["url"], !url.isEmpty else {
            return .failure("open requires a url")
        }

        if let profileName = request.args["profile"] {
            let profile = ProfileManager.shared.profileOrCreate(named: profileName)
            RoutingCoordinator.shared.openURL(url, in: profile)
            return CLIResponse(ok: true, message: "Opened \(url) in profile '\(profile.name)' (explicit --profile).")
        }

        let store = RoutingRulesStore.shared
        let context = RoutingContext(url: url, sourceBundleId: nil)
        let matchedIndex = store.rules.firstIndex { RuleMatcher.matches($0.match, context: context) }
        let profileId = RuleMatcher.resolveProfileId(for: context, rules: store.rules, defaultProfileId: store.defaultProfileId)
        let profile = ProfileManager.shared.profile(id: profileId)
            ?? ProfileManager.shared.profileOrCreate(named: ProfileManager.defaultProfileName)
        RoutingCoordinator.shared.openURL(url, in: profile)

        let matchNote = matchedIndex.map { "matched rule #\($0 + 1)" } ?? "no rule matched, used default profile"
        return CLIResponse(ok: true, message: "Opened \(url) in profile '\(profile.name)' (\(matchNote)).")
    }

    private static func handleProfiles() -> CLIResponse {
        let profiles = ProfileManager.shared.profiles.map { profile -> CLIProfileInfo in
            let windowCount = WindowManager.shared.windowControllers.filter { $0.profile.id == profile.id }.count
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
        for controller in WindowManager.shared.windowControllers {
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
                    url: url
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
