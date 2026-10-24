import Foundation

/// MCP **client** over stdio — the counterpart of our MCP server, mirroring
/// codex's `rmcp-client`: spawn a server process, JSON-RPC handshake,
/// list tools, call tools. Servers are configured like codex's
/// `mcp_servers.toml` at `~/.moppet/brain/mcp.json`.
/// Mutable state is confined to the serial `queue`; @unchecked Sendable is
/// safe under that discipline.
final class BrainMCPClient: @unchecked Sendable {

    struct ServerConfig: Codable {
        var command: String
        var args: [String] = []
        var env: [String: String] = [:]

        // Minimal-entry configs (`{"srv": {"command": "/x"}}`) must not fail
        // the WHOLE dictionary decode — one missing optional-with-default key
        // used to silently disconnect every configured server.
        init(command: String, args: [String] = [], env: [String: String] = [:]) {
            self.command = command
            self.args = args
            self.env = env
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            command = try c.decode(String.self, forKey: .command)
            args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
            env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        }
    }

    struct ToolInfo {
        let name: String
        let description: String
        let schema: [String: Any]
    }

    static var configFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet/brain/mcp.json")
    }

    static func loadConfig() -> [String: ServerConfig] {
        guard let data = try? Data(contentsOf: configFile),
              let dict = try? JSONDecoder().decode([String: ServerConfig].self, from: data) else {
            return [:]
        }
        return dict
    }

    // MARK: - Runtime

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private let queue = DispatchQueue(label: "brain.mcp.client")
    private var buffer = Data()
    private var pending: [(id: Int, continuation: CheckedContinuation<[String: Any], Error>)] = []
    private var nextID = 1
    let serverName: String
    private(set) var tools: [ToolInfo] = []

    init(serverName: String, config: ServerConfig) throws {
        self.serverName = serverName
        process = Process()
        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        // Bare command names (npx/uvx/...) are the MCP ecosystem's norm but
        // Process needs an absolute path — resolve via /usr/bin/which.
        var executable = config.command
        if !config.command.contains("/") {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
            which.arguments = [config.command]
            let pipe = Pipe()
            which.standardOutput = pipe
            which.standardError = FileHandle.nullDevice
            if (try? which.run()) != nil, let path = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                executable = path
            }
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = config.args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in config.env { env[k] = v }
        process.environment = env
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        weak let weakSelf = self
        process.terminationHandler = { _ in
            // Server died: every pending request must fail NOW, not hang the
            // waiting brain turn until forever.
            guard let self = weakSelf else { return }
            self.queue.async { self.failAllPending(BrainError("MCP server '\(serverName)' exited")) }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.queue.async { self.consume(chunk) }
        }
    }

    deinit {
        if process.isRunning { process.terminate() }
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = Data(buffer[buffer.startIndex..<nl])
            buffer = Data(buffer[buffer.index(after: nl)...])
            guard !lineData.isEmpty,
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = (json["id"] as? Int ?? (json["id"] as? String).flatMap(Int.init))
            else { continue }
            // JSON-RPC error responses carry "error", not "result" — the old
            // guard dropped them wholesale and the caller hung forever.
            if let idx = pending.firstIndex(where: { $0.id == id }) {
                let continuation = pending.remove(at: idx).continuation
                if let result = json["result"] as? [String: Any] {
                    continuation.resume(returning: result)
                } else if let error = json["error"] {
                    let message = (error as? [String: Any])?["message"] as? String
                        ?? String(describing: error)
                    continuation.resume(throwing: BrainError("MCP error: \(message)"))
                } else {
                    continuation.resume(throwing: BrainError("MCP response had neither result nor error"))
                }
            }
        }
    }

    private func failAllPending(_ error: Error) {
        for entry in pending {
            entry.continuation.resume(throwing: error)
        }
        pending.removeAll()
    }

    /// Per-request timeout: a wedged server must fail the tool call, not
    /// park the brain turn in isRunning=true until the app quits.
    static let requestTimeout: TimeInterval = 60

    private func request(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let id = queue.sync { () -> Int in
            let value = nextID
            nextID += 1
            return value
        }
        let message: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw BrainError("cannot encode MCP request")
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                guard self.process.isRunning else {
                    continuation.resume(throwing: BrainError("MCP server '\(self.serverName)' is not running"))
                    return
                }
                self.pending.append((id, continuation))
                var payload = data
                payload.append(Data("\n".utf8))
                self.stdinPipe.fileHandleForWriting.write(payload)
                let idCopy = id
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        if let idx = self.pending.firstIndex(where: { $0.id == idCopy }) {
                            let cont = self.pending.remove(at: idx).continuation
                            cont.resume(throwing: BrainError("MCP request timed out after \(Int(Self.requestTimeout))s: \(method)"))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Protocol

    func initialize() async throws {
        _ = try await request("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "moppet-brain", "version": "1.0.0"],
        ])
        // notifications/initialized (no response expected)
        let notification: [String: Any] = [
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: notification) {
            var payload = data
            payload.append(Data("\n".utf8))
            queue.async { self.stdinPipe.fileHandleForWriting.write(payload) }
        }
    }

    @discardableResult
    func listTools() async throws -> [ToolInfo] {
        let result = try await request("tools/list", params: [String: Any]())
        guard let toolArray = result["tools"] as? [[String: Any]] else {
            tools = []
            return []
        }
        tools = toolArray.compactMap { dict in
            guard let name = dict["name"] as? String else { return nil }
            let description = dict["description"] as? String ?? ""
            let schema = dict["inputSchema"] as? [String: Any] ?? ["type": "object"]
            return ToolInfo(name: name, description: description, schema: schema)
        }
        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        let result = try await request("tools/call", params: [
            "name": name, "arguments": arguments,
        ])
        let isError = result["isError"] as? Bool ?? false
        if let content = result["content"] as? [[String: Any]] {
            let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return isError ? "error: \(text)" : text
        }
        return isError ? "error: (no content)" : "(empty result)"
    }

    // MARK: - Resources (codex mcp_resource surface: list / templates / read)

    struct ResourceInfo {
        let uri: String
        let name: String
        let mimeType: String?
        let description: String?
    }

    private func parseResources(_ result: [String: Any]) -> [ResourceInfo] {
        guard let array = result["resources"] as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let uri = dict["uri"] as? String else { return nil }
            return ResourceInfo(uri: uri,
                                name: (dict["name"] as? String) ?? uri,
                                mimeType: dict["mimeType"] as? String,
                                description: dict["description"] as? String)
        }
    }

    /// `resources/list` — single page (cursor pagination is not surfaced to
    /// the model; codex exposes the same single-shot semantics).
    func listResources() async throws -> [ResourceInfo] {
        parseResources(try await request("resources/list", params: [String: Any]()))
    }

    /// `resources/templates/list` — parameterized resource descriptors.
    func listResourceTemplates() async throws -> [ResourceInfo] {
        let result = try await request("resources/templates/list", params: [String: Any]())
        guard let array = result["resourceTemplates"] as? [[String: Any]] else { return [] }
        return array.compactMap { dict in
            guard let uri = dict["uriTemplate"] as? String else { return nil }
            return ResourceInfo(uri: uri,
                                name: (dict["name"] as? String) ?? uri,
                                mimeType: dict["mimeType"] as? String,
                                description: dict["description"] as? String)
        }
    }

    /// `resources/read` — returns the textual contents joined; binary blobs
    /// (base64 blobs without a text-friendly mime) are summarized by size.
    func readResource(uri: String) async throws -> String {
        let result = try await request("resources/read", params: ["uri": uri])
        guard let contents = result["contents"] as? [[String: Any]], !contents.isEmpty else {
            return "(empty resource)"
        }
        var parts: [String] = []
        for content in contents {
            if let text = content["text"] as? String {
                parts.append(text)
            } else if let blob = content["blob"] as? String {
                let approxBytes = blob.utf8.count * 3 / 4
                parts.append("(binary blob, ~\(approxBytes) bytes, mime \((content["mimeType"] as? String) ?? "unknown"))")
            }
        }
        return parts.joined(separator: "\n---\n")
    }
}
