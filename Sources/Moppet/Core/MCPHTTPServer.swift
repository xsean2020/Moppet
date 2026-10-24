import Foundation
import Network
import Observation

/// Streamable-HTTP MCP transport (one JSON-RPC message per POST) built on
/// Network.framework — lets external MCP clients connect to the running app
/// without stdio, with an in-app on/off switch.
final class MCPHTTPServer {

    static let defaultPort: UInt16 = 8765

    private var listener: NWListener?
    private(set) var port: UInt16 = defaultPort
    private let queue = DispatchQueue(label: "mcp.http.server")

    var isRunning: Bool { listener != nil }

    /// Set when the listener fails asynchronously (port taken, etc.) so the
    /// app layer can correct its "running" state — NWListener reports bind
    /// failures only through `stateUpdateHandler`, never from `init`.
    var onFailed: ((String) -> Void)?

    func start(port: UInt16 = MCPHTTPServer.defaultPort) throws {
        guard listener == nil else { return }
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ToolRegistry.ToolError(message: "invalid MCP HTTP port: \(port)")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback ONLY: this endpoint runs destructive tools with no auth —
        // binding every interface would let any LAN device delete files.
        // NOTE: requiredLocalEndpoint carries the PORT too; passing `on:` as
        // well makes Network.framework reject the parameters (NWError 22).
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        self.port = port
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                FileHandle.standardError.write(Data("mcp-http: \(error.localizedDescription)\n".utf8))
                // Without this the switch keeps showing "listening" while
                // nothing is actually bound.
                self.stop()
                self.onFailed?(error.localizedDescription)
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling (minimal HTTP/1.1, close per request)

    private func handle(connection: NWConnection) {
        // One queue per connection: a slow tools/call must not freeze accept
        // and read for every other client sharing the listener queue.
        connection.start(queue: DispatchQueue(label: "mcp.http.conn"))
        receiveRequest(connection: connection, buffer: Data())
    }

    /// Hard cap on request buffering — a peer that streams forever (or lies
    /// about Content-Length) must not grow memory without bound.
    private static let maxRequestBytes = 8 << 20

    private func receiveRequest(connection: NWConnection, buffer: Data) {
        if buffer.count > Self.maxRequestBytes {
            connection.cancel()
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || (isComplete && buffer.isEmpty) {
                connection.cancel()
                return
            }
            if let response = self.dispatch(buffer: buffer) {
                self.send(response: response, connection: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(connection: connection, buffer: buffer)
            }
        }
    }

    /// Parses a full HTTP request once available; nil until headers+body are complete.
    private func dispatch(buffer: Data) -> Data? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: Data(headerData), encoding: .utf8) else {
            return httpError(400, "bad request")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines.first ?? ""
        guard requestLine.hasPrefix("POST") else {
            // GET → plain service info (clients usually probe with GET).
            let info: [String: String] = [
                "service": "moppet-mcp",
                "endpoint": "/mcp",
                "protocol": "streamable-http (single JSON-RPC per POST)",
            ]
            let body = try? JSONSerialization.data(withJSONObject: info)
            return httpResponse(200, body ?? Data("{}".utf8), contentType: "application/json")
        }

        var contentLength = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        guard contentLength >= 0, contentLength <= Self.maxRequestBytes else {
            return httpError(413, "payload too large")
        }
        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }   // wait for full body
        let bodyData = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: max(contentLength, 0))])

        guard bodyData.isEmpty == false,
              let message = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              let response = MCPServer.handleMessage(message),
              let payload = try? JSONSerialization.data(withJSONObject: response) else {
            return httpError(400, "invalid JSON-RPC message")
        }
        return httpResponse(200, payload, contentType: "application/json")
    }

    private func send(response: Data, connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func httpResponse(_ status: Int, _ body: Data, contentType: String) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        default: reason = "Error"
        }
        let head = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private func httpError(_ status: Int, _ message: String) -> Data {
        httpResponse(status, Data("{\"error\":\"\(message)\"}".utf8), contentType: "application/json")
    }
}

/// App-facing switch: persisted enabled state, auto-start on launch.
@Observable
final class MCPAppService {
    static let shared = MCPAppService()
    static let enabledKey = "mcp.http.enabled"
    static let portKey = "mcp.http.port"

    private let server = MCPHTTPServer()
    var errorMessage: String?
    /// Tracked mirror of the server's state — computed properties over the
    /// NWListener are invisible to @Observable, so stop/fail (and the stop
    /// path in general) would leave the toggle frozen on "running".
    private(set) var isRunning = false

    init() {
        server.onFailed = { [weak self] message in
            Task { @MainActor in
                self?.isRunning = false
                self?.errorMessage = "listener failed: \(message)"
            }
        }
    }
    var port: UInt16 {
        get {
            server.isRunning ? server.port
                : UInt16(UserDefaults.standard.integer(forKey: Self.portKey)) == 0
                    ? MCPHTTPServer.defaultPort
                    : UInt16(UserDefaults.standard.integer(forKey: Self.portKey))
        }
        set {
            UserDefaults.standard.set(Int(newValue), forKey: Self.portKey)
            if server.isRunning {
                setEnabled(false)
                setEnabled(true)
            }
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var endpointURL: String {
        "http://127.0.0.1:\(port)/mcp"
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            do {
                try server.start(port: port)
                errorMessage = nil
                isRunning = true
                PetBus.shared.say("MCP server on → \(endpointURL)", state: .celebrating)
            } catch {
                isRunning = false
                errorMessage = "port \(port) unavailable: \(error.localizedDescription)"
            }
        } else {
            server.stop()
            isRunning = false
        }
    }

    /// Called at app launch to honor the persisted switch.
    func restoreAtLaunch() {
        if isEnabled {
            setEnabled(true)
        }
    }
}
