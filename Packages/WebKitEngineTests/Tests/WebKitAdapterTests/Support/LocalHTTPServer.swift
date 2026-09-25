import Foundation
import Network

/// A minimal HTTP/1.1 server on 127.0.0.1 for the WebKit adapter tests: a
/// fixed route table, one response per connection, then close. Real HTTP
/// rather than loadHTMLString so response headers (Content-Disposition), the
/// navigation-response policy and subframe loads all go through WebKit's
/// actual network path.
final class LocalHTTPServer {
    struct Response {
        var status = 200
        var contentType = "text/html; charset=utf-8"
        var headers: [String: String] = [:]
        var body: Data

        static func html(_ html: String) -> Response {
            Response(body: Data(html.utf8))
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private let routes: [String: Response]
    private(set) var port: UInt16 = 0

    init(routes: [String: Response]) throws {
        self.routes = routes
        let parameters = NWParameters.tcp
        // Loopback only, so the test run never trips the application firewall.
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            throw NSError(domain: "LocalHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        if let failure { throw failure }
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

    func url(_ path: String) -> String {
        "http://127.0.0.1:\(port)\(path)"
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let response = routes[path] ?? Response(status: 404, contentType: "text/plain", body: Data("not found".utf8))

        var lines = ["HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Error")",
                     "Content-Type: \(response.contentType)",
                     "Content-Length: \(response.body.count)",
                     "Cache-Control: no-store",
                     "Connection: close"]
        for (name, value) in response.headers { lines.append("\(name): \(value)") }
        var payload = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
