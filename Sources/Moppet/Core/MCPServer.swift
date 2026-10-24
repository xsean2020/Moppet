import Foundation

/// Minimal MCP (Model Context Protocol) server over stdio — newline-delimited
/// JSON-RPC 2.0. This exposes every ToolRegistry tool to external AI agents
/// (Claude Code, Cursor, …), which is the modern counterpart of mole's
/// Claude/Codex skills: the agent conversationally confirms with the user,
/// then passes `"confirmed": true` for destructive tools.
///
/// Launch: `Moppet --mcp`
/// Client config:
///   { "mcpServers": { "moppet": { "command": "/path/to/Moppet", "args": ["--mcp"] } } }
enum MCPServer {

    static let protocolVersion = "2024-11-05"

    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        FileHandle.standardInput.readLinesHandler { line in
            handle(line: line)
        }
        // readLinesHandler blocks until EOF; nothing after it.
        exit(0)
    }

    // MARK: - Dispatch

    private static func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let message = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            log("unparseable line: \(trimmed.prefix(200))")
            return
        }
        if let response = handleMessage(message), let data = encode(response) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    /// Transport-agnostic JSON-RPC dispatch (stdio + HTTP share this).
    /// Returns nil for notifications (no response required).
    static func handleMessage(_ message: [String: Any]) -> [String: Any]? {
        // Notifications (no id) get no response.
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""

        switch method {
        case "initialize":
            return response(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "moppet", "version": "1.0.0"],
            ])
        case "ping":
            return response(id: id, result: [String: Any]())
        case "tools/list":
            return response(id: id, result: [
                "tools": ToolRegistry.tools.map { tool in
                    [
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.jsonSchema,
                    ] as [String: Any]
                }
            ])
        case "tools/call":
            return toolCallResponse(id: id, params: message["params"] as? [String: Any] ?? [:])
        case "resources/list":
            return response(id: id, result: ["resources": [[String: Any]]()])
        case "prompts/list":
            return response(id: id, result: ["prompts": [[String: Any]]()])
        default:
            return response(id: id, error: ["code": -32601, "message": "method not found: \(method)"])
        }
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    private static func toolCallResponse(id: Any, params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return response(id: id, error: ["code": -32602, "message": "missing tool name"])
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        // Lock-guarded result box: the detached task writes, the waiter reads
        // — the old bare `var payload` was a data race.
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: [String: Any]?
            func set(_ v: [String: Any]) { lock.lock(); value = v; lock.unlock() }
            func get() -> [String: Any]? { lock.lock(); defer { lock.unlock() }; return value }
        }
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            defer { semaphore.signal() }
            do {
                let text = try await ToolRegistry.execute(name: name, args: args, approval: .confirmedFlag)
                box.set(["content": [["type": "text", "text": text]], "isError": false] as [String: Any])
            } catch {
                box.set(["content": [["type": "text", "text": "error: \(error.localizedDescription)"]],
                         "isError": true] as [String: Any])
            }
        }
        // On timeout CANCEL the tool (it may be destructive — letting it run
        // on while telling the client "error" invited a double execution).
        if semaphore.wait(timeout: .now() + 600) == .timedOut {
            task.cancel()
            _ = semaphore.wait(timeout: .now() + 5)   // let cancellation land
        }
        return response(id: id, result: box.get() ?? [
            "content": [["type": "text",
                        "text": "internal error: tool timed out and was cancelled — do NOT retry blindly"]],
            "isError": true,
        ])
    }

    private static func response(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func response(id: Any, error: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": error]
    }

    // MARK: - IO

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

extension FileHandle {
    /// Reads stdin line-by-line on a background thread, invoking the handler
    /// synchronously per line; returns only after EOF.
    func readLinesHandler(_ handler: @escaping (String) -> Void) {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { semaphore.signal() }
            var buffer = Data()
            while true {
                let chunk = availableData
                if chunk.isEmpty { break }    // EOF
                buffer.append(chunk)
                while let nlIndex = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<nlIndex]
                    if let line = String(data: Data(lineData), encoding: .utf8) {
                        handler(line)
                    }
                    buffer = Data(buffer[buffer.index(after: nlIndex)...])
                }
            }
        }
        semaphore.wait()
    }
}
