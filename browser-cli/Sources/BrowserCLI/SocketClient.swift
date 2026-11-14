import Foundation
import Darwin
import BrowserCLIProtocol

public enum SocketClientError: Error, CustomStringConvertible {
    case noRunningInstance(path: String)
    case untrustedPeer(path: String)
    case malformedResponse

    public var description: String {
        switch self {
        case .noRunningInstance(let path):
            return "Cannot connect to Browser socket at \(String(reflecting: path)). Launch the intended instance and check socket access permissions. Select its path with --socket or BROWSER_CLI_SOCKET, or unset the override and use --profiles-root for discovery."
        case .untrustedPeer(let path):
            return "Refusing Browser socket at \(String(reflecting: path)): cannot verify that the connected peer belongs to the current user. No request was sent."
        case .malformedResponse:
            return "Received a malformed response from the running Browser instance."
        }
    }
}

/// Client side of `Sources/App/CLI/CLIServer.swift`'s Unix domain socket --
/// see that file's own doc comment for the framing (one newline-terminated
/// JSON object each way, one connection per request). Raw POSIX sockets,
/// same reasoning as the server side: this is macOS-only code either way,
/// and there's no ambiguity to resolve about Unix-domain-socket support the
/// way there would be reaching for Network.framework here (confirmed absent
/// from this SDK's public NWEndpoint surface while building the app side).
public enum SocketClient {
    public static func send(_ request: CLIRequest, socketPath: String) throws -> CLIResponse {
        _ = try SocketTargetResolver.validate(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketClientError.noRunningInstance(path: socketPath) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < sunPathSize else {
            throw SocketClientError.noRunningInstance(path: socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: sunPathSize) { rebound in
                for (index, byte) in pathBytes.enumerated() { rebound[index] = byte }
                rebound[pathBytes.count] = 0
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { rawAddr in
            rawAddr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw SocketClientError.noRunningInstance(path: socketPath)
        }

        // Verify the connected endpoint, not its pathname: a filesystem check
        // alone can race a replacement listener before connect completes.
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else {
            throw SocketClientError.untrustedPeer(path: socketPath)
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        let written = payload.withUnsafeBytes { raw in
            write(fd, raw.baseAddress, raw.count)
        }
        guard written == payload.count else {
            throw SocketClientError.malformedResponse
        }

        // A snapshot can run to hundreds of kilobytes, so read in chunks.
        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        reading: while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            for index in 0..<n {
                if chunk[index] == 0x0A { break reading }
                buffer.append(chunk[index])
            }
        }
        guard !buffer.isEmpty, let response = try? JSONDecoder().decode(CLIResponse.self, from: Data(buffer)) else {
            throw SocketClientError.malformedResponse
        }
        return response
    }
}
