import Foundation

/// Chrome's native messaging, for extensions that talk to an app on this Mac
/// (`runtime.sendNativeMessage` / `runtime.connectNative`). Apps install a
/// host manifest into Chrome's own `NativeMessagingHosts` folders, so hosts
/// are found there and spoken to exactly as Chrome does: the manifest's
/// `path` is started with the caller's origin as its only argument, and
/// messages cross its stdin/stdout as a native-endian UInt32 byte length
/// followed by that many bytes of UTF-8 JSON.
/// https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging
public struct NativeMessagingManifest: Decodable, Equatable {
    public let name: String
    public let path: String
    public let type: String
    public let allowedOrigins: [String]

    private enum CodingKeys: String, CodingKey {
        case name, path, type
        case allowedOrigins = "allowed_origins"
    }
}

public enum NativeMessagingError: Error, Equatable, CustomStringConvertible {
    case invalidHostName(String)
    case hostNotFound(String)
    case invalidManifest(String)
    case forbidden(host: String, origin: String)
    case messageTooLarge(Int)
    case invalidMessage
    case hostExited

    /// Chrome's own wording where it has one, since extensions sometimes
    /// compare `runtime.lastError.message` against it.
    public var description: String {
        switch self {
        case .invalidHostName: return "Invalid native messaging host name specified."
        case .hostNotFound: return "Specified native messaging host not found."
        case .invalidManifest(let reason): return "Invalid native messaging host manifest: \(reason)"
        case .forbidden: return "Access to the specified native messaging host is forbidden."
        case .messageTooLarge: return "Native messaging message is too large."
        case .invalidMessage: return "Error when communicating with the native messaging host."
        case .hostExited: return "Native host has exited."
        }
    }
}

public enum NativeMessagingHostLocator {
    /// Chrome's own folders first, per user before system-wide, then Edge's
    /// and Chromium's: some hosts are only installed for one of them.
    public static func defaultDirectories(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support")
        return [
            support.appendingPathComponent("Google/Chrome/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts"),
            support.appendingPathComponent("Microsoft Edge/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Microsoft/Edge/NativeMessagingHosts"),
            support.appendingPathComponent("Chromium/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts"),
        ]
    }

    /// Chrome's rule: dot-separated runs of lowercase letters, digits and
    /// underscores. It also keeps a name from walking out of the folder.
    public static func isValidHostName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
        }
    }

    /// The first folder holding `<name>.json` decides, as in Chrome: a
    /// manifest there that refuses `origin` is not skipped for a later one
    /// that might allow it.
    public static func find(name: String, origin: String, directories: [URL] = defaultDirectories()) throws -> NativeMessagingManifest {
        guard isValidHostName(name) else { throw NativeMessagingError.invalidHostName(name) }
        let fileManager = FileManager.default
        guard let file = directories
            .map({ $0.appendingPathComponent(name + ".json") })
            .first(where: { fileManager.fileExists(atPath: $0.path) })
        else { throw NativeMessagingError.hostNotFound(name) }

        let manifest: NativeMessagingManifest
        do {
            manifest = try JSONDecoder().decode(NativeMessagingManifest.self, from: Data(contentsOf: file))
        } catch {
            throw NativeMessagingError.invalidManifest("\(file.lastPathComponent) does not parse")
        }
        guard manifest.name == name else { throw NativeMessagingError.invalidManifest("name does not match the file") }
        guard manifest.type == "stdio" else { throw NativeMessagingError.invalidManifest("type must be stdio") }
        guard manifest.path.hasPrefix("/") else { throw NativeMessagingError.invalidManifest("path must be absolute on macOS") }
        guard manifest.allowedOrigins.contains(origin) else { throw NativeMessagingError.forbidden(host: name, origin: origin) }
        return manifest
    }
}

public enum NativeMessagingFrame {
    /// Chrome's limit on one message from a host.
    public static let maximumFromHost = 1024 * 1024
    /// Chrome allows up to 4 GB towards a host. Nothing real comes close,
    /// and a bound keeps one runaway extension from filling memory.
    public static let maximumToHost = 64 * 1024 * 1024

    public static func encode(_ message: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject([message]) else { throw NativeMessagingError.invalidMessage }
        let body = try JSONSerialization.data(withJSONObject: message, options: [.fragmentsAllowed])
        guard body.count <= maximumToHost else { throw NativeMessagingError.messageTooLarge(body.count) }
        var length = UInt32(body.count)
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    /// Collects stdout in whatever pieces the pipe delivers and returns each
    /// whole message as it completes.
    public struct Reader {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ data: Data) throws -> [Any] {
            buffer.append(data)
            var messages: [Any] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
                guard length <= NativeMessagingFrame.maximumFromHost else { throw NativeMessagingError.messageTooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
                buffer = Data(buffer.dropFirst(4 + length))
                guard let message = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
                    throw NativeMessagingError.invalidMessage
                }
                messages.append(message)
            }
            return messages
        }
    }
}

/// One running host. `onMessage` and `onExit` are called on `queue`, and
/// `onExit` exactly once: with nil when `stop()` ended it, otherwise with the
/// reason it ended by itself.
public final class NativeMessagingHostProcess {
    public var onMessage: ((Any) -> Void)?
    public var onExit: ((NativeMessagingError?) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var reader = NativeMessagingFrame.Reader()
    private var finished = false

    public init(manifest: NativeMessagingManifest, origin: String, queue: DispatchQueue = .main) {
        self.queue = queue
        let executable = URL(fileURLWithPath: manifest.path)
        process.executableURL = executable
        process.arguments = [origin]
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    public func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.finish(.hostExited)
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw NativeMessagingError.hostNotFound(process.executableURL?.path ?? "")
        }
    }

    public func send(_ message: Any) throws {
        let frame = try NativeMessagingFrame.encode(message)
        lock.lock()
        let isFinished = finished
        lock.unlock()
        guard !isFinished else { throw NativeMessagingError.hostExited }
        do {
            try input.fileHandleForWriting.write(contentsOf: frame)
        } catch {
            throw NativeMessagingError.hostExited
        }
    }

    public func stop() {
        finish(nil)
    }

    private func read(_ data: Data) {
        guard !data.isEmpty else { return }
        let messages: [Any]
        lock.lock()
        do {
            messages = try reader.append(data)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(error as? NativeMessagingError ?? .invalidMessage)
            return
        }
        for message in messages {
            queue.async { [weak self] in
                guard let self, !self.wasStopped else { return }
                self.onMessage?(message)
            }
        }
    }

    /// True once `stop()` was called: nothing is delivered after that.
    private var wasStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private var stopped = false

    private func finish(_ reason: NativeMessagingError?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        if reason == nil { stopped = true }
        lock.unlock()

        output.fileHandleForReading.readabilityHandler = nil
        // A host commonly writes its reply and exits at once, and the exit
        // can be seen before the reply is read. What is still in the pipe is
        // read before the exit is reported, so the reply is not lost.
        if reason == .hostExited {
            read(output.fileHandleForReading.readDataToEndOfFile())
        }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        queue.async { [weak self] in
            self?.onExit?(reason)
            self?.onMessage = nil
            self?.onExit = nil
        }
    }
}
