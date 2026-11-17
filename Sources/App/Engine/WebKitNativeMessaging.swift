import WebKit

/// `runtime.sendNativeMessage` and `runtime.connectNative` for WebKit
/// extensions, through the same host manifests Chrome uses
/// (`NativeMessagingHostLocator`). This is what lets an extension that
/// needs a helper app work here, such as Microsoft's Single Sign On
/// extension and Company Portal's BrowserCore helper, which together pass
/// Entra's device check. A host only ever runs for an extension the user
/// granted `nativeMessaging`, and only if its manifest lists that
/// extension's chrome-extension:// origin.
@available(macOS 15.4, *)
@MainActor
enum WebKitNativeMessaging {
    /// An open `connectNative` port and its host. A host lives until either
    /// side disconnects, its extension is unloaded, or the background content
    /// that was running when the port opened goes away.
    private final class Connection {
        let host: NativeMessagingHostProcess
        weak var port: WKWebExtension.MessagePort?
        weak var context: WKWebExtensionContext?
        /// The background web view running when the port opened. WebKit
        /// replaces the view whenever it restarts the background content
        /// (idle unload, crash, a new user agent). Closing the old view
        /// normally disconnects its native ports, but not on every path, so
        /// a connection whose view is gone or replaced is treated as stale
        /// rather than trusted to be disconnected.
        weak var background: WKWebView?
        /// False for a port opened while no background content ran (from
        /// an extension page): it neither keeps the background loaded nor
        /// ends with it.
        let tiedToBackground: Bool

        init(host: NativeMessagingHostProcess, port: WKWebExtension.MessagePort, context: WKWebExtensionContext,
             background: WKWebView?, tiedToBackground: Bool) {
            self.host = host
            self.port = port
            self.context = context
            self.background = background
            self.tiedToBackground = tiedToBackground
        }
    }

    private static var connections: [ObjectIdentifier: Connection] = [:]

    /// `onChange` ports to the settings host, answered inside the app. They
    /// are not Connections: no process stands behind them, so the stale-host
    /// cleanup has nothing to stop, and they never keep background content
    /// loaded -- a page listening for a setting is no reason to keep a
    /// worker running.
    private final class SettingsPort {
        weak var port: WKWebExtension.MessagePort?
        weak var context: WKWebExtensionContext?
        let subscription: NSObjectProtocol

        init(port: WKWebExtension.MessagePort, context: WKWebExtensionContext, subscription: NSObjectProtocol) {
            self.port = port
            self.context = context
            self.subscription = subscription
        }
    }

    private static var settingsPorts: [ObjectIdentifier: SettingsPort] = [:]

    /// WebKit unloads non-persistent background content 30 seconds after it
    /// was last woken, unless the background page posted on one of its ports
    /// in the last two minutes (`WebExtensionContext::scheduleBackgroundContentToUnload`
    /// and `unloadBackgroundContentIfPossible`). Messages arriving *from* a
    /// native host do not count, so a worker that only listens on its native
    /// port -- iCloud Passwords once paired -- is unloaded about two minutes
    /// after it last posted, and its in-memory session is lost. Chrome instead
    /// keeps a service worker alive for as long as it holds a native port,
    /// and extensions rely on that. `loadBackgroundContent` restarts WebKit's
    /// 30-second timer whenever the content is already loaded, so calling it
    /// more often than that gives Chrome's rule. The cost is Chrome's too: an
    /// extension that opens a native port and never closes it keeps its
    /// background content for the rest of the session.
    static var keepAliveInterval: TimeInterval = 20
    private static var keepAliveTimer: Timer?

    /// Where host manifests are looked for; tests point it at their own.
    static var hostDirectories: [URL] = NativeMessagingHostLocator.defaultDirectories()

    private static let backgroundWebViewSelector = NSSelectorFromString("_backgroundWebView")

    /// `_backgroundWebView` is private SPI. Without it a connection cannot be
    /// tied to its background content, so every port keeps the background
    /// content loaded and only a disconnect or an unload stops its host.
    private static let canSeeBackground = WKWebExtensionContext.instancesRespond(to: backgroundWebViewSelector)

    private static func backgroundWebView(of context: WKWebExtensionContext) -> WKWebView? {
        guard canSeeBackground else { return nil }
        return context.perform(backgroundWebViewSelector)?.takeUnretainedValue() as? WKWebView
    }

    /// One message and its reply: the host is started, sent the message,
    /// and stopped after its first reply, as Chrome does.
    /// `profileId` and `privacyGranted` describe the calling extension as the
    /// app knows it: its profile, and whether the user granted it `privacy`
    /// (a permission WebKit itself does not know, so only the app's record of
    /// the grant can say).
    static func sendMessage(_ message: Any, toHost name: String?, from context: WKWebExtensionContext,
                            profileId: String?, privacyGranted: Bool) async throws -> Any? {
        if name == ChromeExtensionCompatibility.settingsHost {
            return try settingsProvider(for: context, profileId: profileId, privacyGranted: privacyGranted)
                .handle(message, from: context.uniqueIdentifier, profileId: profileId ?? "")
        }
        let manifest = try manifest(named: name, for: context)
        let host = NativeMessagingHostProcess(manifest: manifest, origin: origin(of: context))
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            func resume(_ result: Result<Any?, Error>) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            host.onMessage = { reply in
                resume(.success(reply))
                host.stop()
            }
            host.onExit = { reason in
                if let reason { logExit(of: host, reason) }
                resume(.failure(error(reason ?? NativeMessagingError.hostExited)))
            }
            do {
                try host.start()
                try host.send(message)
            } catch {
                host.stop()
                resume(.failure(Self.error(error)))
            }
        }
    }

    static func connect(_ port: WKWebExtension.MessagePort, from context: WKWebExtensionContext,
                        profileId: String?, privacyGranted: Bool) throws {
        if port.applicationIdentifier == ChromeExtensionCompatibility.settingsHost {
            try listenToSettings(on: port, from: context, profileId: profileId, privacyGranted: privacyGranted)
            return
        }
        // A restarted worker reconnects as it starts: the hosts its previous
        // run left behind are stopped before the new one starts.
        stopStaleHosts()
        let manifest = try manifest(named: port.applicationIdentifier, for: context)
        let host = NativeMessagingHostProcess(manifest: manifest, origin: origin(of: context))
        let key = ObjectIdentifier(port)

        host.onMessage = { [weak port] message in
            port?.sendMessage(message) { _ in }
        }
        host.onExit = { [weak port, weak host, weak context] reason in
            if let reason, let host { logExit(of: host, reason) }
            if connections[key]?.host === host {
                connections[key] = nil
                announce(context)
            }
            guard let port, !port.isDisconnected else { return }
            port.disconnect(throwing: reason.map { error($0) })
        }
        port.messageHandler = { [weak host] message, _ in
            guard let host, let message else { return }
            do {
                try host.send(message)
            } catch {
                NSLog("Browser: native messaging send failed: %@", "\(error)")
                host.stop()
            }
        }
        port.disconnectHandler = { [weak context] _ in
            if let removed = connections.removeValue(forKey: key) {
                removed.host.stop()
                announce(context)
            }
            updateKeepAlive()
        }
        let background = backgroundWebView(of: context)
        connections[key] = Connection(host: host, port: port, context: context, background: background,
                                      tiedToBackground: background != nil || !canSeeBackground)
        do {
            try host.start()
        } catch {
            connections[key] = nil
            throw Self.error(error)
        }
        updateKeepAlive()
        announce(context)
    }

    /// Told, on a later turn, whenever a context's set of running hosts
    /// changed (`hostProcessIdentifiers(for:)`).
    static var hostsDidChange: ((WKWebExtensionContext) -> Void)?

    private static func announce(_ context: WKWebExtensionContext?) {
        DispatchQueue.main.async { [weak context] in
            guard let context else { return }
            MainActor.assumeIsolated { hostsDidChange?(context) }
        }
    }

    /// Stops every host started for `context`, for an extension being
    /// unloaded (disabled, removed, reloaded, updated, or its profile closed).
    static func stopHosts(for context: WKWebExtensionContext) {
        stop(connections.filter { $0.value.context === context || $0.value.context == nil }, because: "its extension was unloaded")
        updateKeepAlive()
        for (key, listener) in settingsPorts where listener.context === context || listener.context == nil {
            endSettingsPort(key)
            if let port = listener.port, !port.isDisconnected { port.disconnect() }
        }
    }

    // MARK: - The settings host

    /// The browser answers `ChromeExtensionCompatibility.settingsHost`
    /// itself (ExtensionSettingsHost.provider), for an extension the user
    /// granted `privacy`. The extension is the one WebKit names as the
    /// sender, never one a message names.
    private static func settingsProvider(for context: WKWebExtensionContext, profileId: String?,
                                         privacyGranted: Bool) throws -> ExtensionSettingsProvider {
        let name = ChromeExtensionCompatibility.settingsHost
        guard let provider = ExtensionSettingsHost.provider, profileId != nil else {
            throw error(NativeMessagingError.hostNotFound(name))
        }
        guard privacyGranted else {
            throw error(NativeMessagingError.forbidden(host: name, origin: origin(of: context)))
        }
        return provider
    }

    private static func listenToSettings(on port: WKWebExtension.MessagePort, from context: WKWebExtensionContext,
                                         profileId: String?, privacyGranted: Bool) throws {
        let provider = try settingsProvider(for: context, profileId: profileId, privacyGranted: privacyGranted)
        let key = ObjectIdentifier(port)
        // A listener whose page or worker went away without its port being
        // disconnected is dropped at the first change that fails to reach it.
        let subscription = provider.subscribe(extensionId: context.uniqueIdentifier, profileId: profileId ?? "") { [weak port] message in
            guard let port, !port.isDisconnected else { return endSettingsPort(key) }
            port.sendMessage(message) { failure in
                if failure != nil { MainActor.assumeIsolated { endSettingsPort(key) } }
            }
        }
        port.messageHandler = { _, _ in }
        port.disconnectHandler = { _ in endSettingsPort(key) }
        settingsPorts[key] = SettingsPort(port: port, context: context, subscription: subscription)
    }

    private static func endSettingsPort(_ key: ObjectIdentifier) {
        guard let listener = settingsPorts.removeValue(forKey: key) else { return }
        ExtensionSettingsHost.provider?.unsubscribe(listener.subscription)
    }

    /// Open settings ports for `context`, for tests.
    static func settingsPortCount(for context: WKWebExtensionContext) -> Int {
        settingsPorts.values.filter { $0.context === context }.count
    }

    /// Whether the keep-alive timer is running, for tests.
    static var isKeepingBackgroundsAlive: Bool { keepAliveTimer != nil }

    /// The process ids of the hosts running for `context`.
    static func hostProcessIdentifiers(for context: WKWebExtensionContext) -> [Int32] {
        connections.values.filter { $0.context === context }.map(\.host.processIdentifier)
    }

    /// A connection is stale once its extension is gone, or once the
    /// background content it was opened under has been unloaded or replaced.
    private static func isStale(_ connection: Connection) -> Bool {
        guard let context = connection.context else { return true }
        guard canSeeBackground, connection.tiedToBackground else { return false }
        guard let background = connection.background else { return true }
        return backgroundWebView(of: context) !== background
    }

    private static func stopStaleHosts() {
        stop(connections.filter { isStale($0.value) }, because: "the background content it was started for is gone")
    }

    private static func stop(_ stale: [ObjectIdentifier: Connection], because reason: String) {
        for (key, connection) in stale {
            connections[key] = nil
            NSLog("Browser: stopping native messaging host %@ (pid %d): %@",
                  connection.host.name, connection.host.processIdentifier, reason)
            connection.host.stop()
            if let port = connection.port, !port.isDisconnected { port.disconnect() }
            announce(connection.context)
        }
    }

    /// Runs while some open port is tied to running background content.
    private static func updateKeepAlive() {
        let needed = connections.values.contains { $0.tiedToBackground }
        if needed, keepAliveTimer == nil {
            let timer = Timer(timeInterval: keepAliveInterval, repeats: true) { _ in
                MainActor.assumeIsolated { keepBackgroundsAlive() }
            }
            RunLoop.main.add(timer, forMode: .common)
            keepAliveTimer = timer
        } else if !needed {
            keepAliveTimer?.invalidate()
            keepAliveTimer = nil
        }
    }

    /// Never wakes background content that is not running: a connection
    /// whose background is gone is stopped instead, and only the contexts
    /// whose background is still the one their ports opened under are
    /// kept loaded.
    private static func keepBackgroundsAlive() {
        stopStaleHosts()
        var kept = Set<ObjectIdentifier>()
        for connection in connections.values where connection.tiedToBackground {
            guard let context = connection.context, kept.insert(ObjectIdentifier(context)).inserted else { continue }
            context.loadBackgroundContent { _ in }
        }
        updateKeepAlive()
    }

    /// A host that ends by itself is logged with how it ended; without it,
    /// a host the system refuses to start looks to the extension like one
    /// that is not installed, and to everyone else like nothing at all.
    private static func logExit(of host: NativeMessagingHostProcess, _ reason: NativeMessagingError) {
        NSLog("Browser: native messaging host %@", host.exitSummary(for: reason))
    }

    private static func manifest(named name: String?, for context: WKWebExtensionContext) throws -> NativeMessagingManifest {
        guard context.hasPermission(.nativeMessaging) else {
            throw error(NativeMessagingError.forbidden(host: name ?? "", origin: origin(of: context)))
        }
        guard let name else { throw error(NativeMessagingError.invalidHostName("")) }
        do {
            return try NativeMessagingHostLocator.find(name: name, origin: origin(of: context), directories: hostDirectories)
        } catch {
            NSLog("Browser: native messaging host %@ refused for %@: %@", name, origin(of: context), "\(error)")
            throw Self.error(error)
        }
    }

    /// The address Chrome gives the extension, which host manifests list in
    /// `allowed_origins` -- stable because `baseURL` is set from the
    /// extension's store id (`WebKitExtensionManager.start`).
    private static func origin(of context: WKWebExtensionContext) -> String {
        context.baseURL.absoluteString
    }

    /// WebKit hands an error's description to the extension as
    /// `runtime.lastError.message`.
    private static func error(_ error: Error) -> NSError {
        let description = (error as? NativeMessagingError)?.description ?? error.localizedDescription
        return NSError(domain: "dev.stroud.browser.nativeMessaging", code: 1, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
