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
    /// Open `connectNative` ports and their hosts. A host lives until either
    /// side disconnects.
    private static var connections: [ObjectIdentifier: NativeMessagingHostProcess] = [:]

    /// One message and its reply: the host is started, sent the message,
    /// and stopped after its first reply, as Chrome does.
    static func sendMessage(_ message: Any, toHost name: String?, from context: WKWebExtensionContext) async throws -> Any? {
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

    static func connect(_ port: WKWebExtension.MessagePort, from context: WKWebExtensionContext) throws {
        let manifest = try manifest(named: port.applicationIdentifier, for: context)
        let host = NativeMessagingHostProcess(manifest: manifest, origin: origin(of: context))
        let key = ObjectIdentifier(port)

        host.onMessage = { [weak port] message in
            port?.sendMessage(message) { _ in }
        }
        host.onExit = { [weak port] reason in
            connections[key] = nil
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
        port.disconnectHandler = { _ in
            connections.removeValue(forKey: key)?.stop()
        }
        connections[key] = host
        do {
            try host.start()
        } catch {
            connections[key] = nil
            throw Self.error(error)
        }
    }

    private static func manifest(named name: String?, for context: WKWebExtensionContext) throws -> NativeMessagingManifest {
        guard context.hasPermission(.nativeMessaging) else {
            throw error(NativeMessagingError.forbidden(host: name ?? "", origin: origin(of: context)))
        }
        guard let name else { throw error(NativeMessagingError.invalidHostName("")) }
        do {
            return try NativeMessagingHostLocator.find(name: name, origin: origin(of: context))
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
