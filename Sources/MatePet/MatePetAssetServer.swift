import Foundation
import Network

/// Tiny read-only HTTP/1.1 server for the pet page and its assets.
///
/// Why a server at all: WKWebView loaded from `file://` gets an opaque origin,
/// and WebKit then refuses ES-module imports plus the binary `fetch` that
/// GLTFLoader uses to read a `.vrm`. A loopback HTTP origin gives the page a
/// normal origin, so three-vrm, import maps and the 26 MB VRM all load without
/// private WebKit flags.
///
/// Security posture:
/// - binds `127.0.0.1` on a random ephemeral port only (never 0.0.0.0),
/// - resolves symlinks and requires the final path to stay inside the bundle's
///   `Resources` directory,
/// - serves only a small extension allow-list,
/// - no directory listing, no request bodies, no keep-alive, one request per
///   connection, closed immediately after the response,
/// - stops when the engine deinits.
final class MatePetAssetServer {

    private let root: URL
    private let queue = DispatchQueue(label: "matepet.assets")
    private static let verbose = ProcessInfo.processInfo.environment["MOPPET_MATE_PET_DEV"] != nil
    private var listener: NWListener?
    private var started = false

    /// Maximum header size we will buffer. A GET request is a few hundred
    /// bytes; anything larger is garbage and gets cut off.
    private static let maxHeaderBytes = 64 * 1024

    private static let allowedExtensions: Set<String> = [
        "html", "js", "mjs", "css", "json", "vrm", "vrma", "glb", "gltf",
        "png", "jpg", "jpeg", "webp", "gif", "svg", "wasm", "bin",
        "woff", "woff2", "ttf", "otf",
    ]

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Starts the listener. `onReady` receives the assigned port; both
    /// callbacks are delivered on the main queue.
    func start(onReady: @escaping (UInt16) -> Void,
               onError: @escaping (String) -> Void) {
        guard !started else { return }
        started = true

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only. `requiredLocalEndpoint` carries the port too; passing
        // a separate `on:` argument makes Network.framework reject the
        // parameters (the MCP server hit the same NWError 22).
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        if Self.verbose {
            FileHandle.standardError.write(Data("mate-pet: asset server root=\(root.path)\n".utf8))
        }
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let port = listener.port?.rawValue ?? 0
                    if Self.verbose {
                        FileHandle.standardError.write(Data("mate-pet: asset server on \(port)\n".utf8))
                    }
                    guard port > 0 else {
                        RunLoop.main.perform {
                            onError("asset server did not receive a port")
                        }
                        return
                    }
                    RunLoop.main.perform { onReady(port) }
                case .failed(let error):
                    RunLoop.main.perform {
                        onError("asset server failed: \(error.localizedDescription)")
                    }
                    self.stop()
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            onError("asset server could not start: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        started = false
    }

    // MARK: - Request handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        if buffer.count > Self.maxHeaderBytes {
            respond(connection, status: 413, "Payload Too Large", body: Data())
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = buffer[..<range.lowerBound]
                self.respond(to: header, on: connection)
                return
            }
            if isComplete || error != nil {
                self.respond(connection, status: 400, "Bad Request", body: Data())
                return
            }
            self.receiveHeader(connection, buffer: buffer)
        }
    }

    private func respond(to header: Data, on connection: NWConnection) {
        let text = String(decoding: header, as: UTF8.self)
        guard let requestLine = text.split(separator: "\r\n").first else {
            respond(connection, status: 400, "Bad Request", body: Data())
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            respond(connection, status: 405, "Method Not Allowed", body: Data())
            return
        }

        var path = String(parts[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        path = path.removingPercentEncoding ?? path
        if path.isEmpty || path == "/" { path = "/mate-pet.html" }

        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let candidate = root.appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        // Path traversal guard: the resolved file must live under root.
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix) else {
            respond(connection, status: 403, "Forbidden", body: Data())
            return
        }
        guard Self.allowedExtensions.contains(candidate.pathExtension.lowercased()) else {
            respond(connection, status: 403, "Forbidden", body: Data())
            return
        }

        guard let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]) else {
            respond(connection, status: 404, "Not Found", body: Data())
            return
        }

        let isHead = parts[0] == "HEAD"
        send(connection, status: 200, reason: "OK",
             contentType: Self.mimeType(for: candidate.pathExtension.lowercased()),
             body: isHead ? Data() : data,
             contentLength: data.count)
    }

    // MARK: - Responses

    private func respond(_ connection: NWConnection, status: Int, _ reason: String, body: Data) {
        send(connection, status: status, reason: reason,
             contentType: "text/plain; charset=utf-8",
             body: body, contentLength: body.count)
    }

    private func send(_ connection: NWConnection,
                      status: Int,
                      reason: String,
                      contentType: String,
                      body: Data,
                      contentLength: Int) {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(contentLength)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Cross-Origin-Resource-Policy: cross-origin\r\n"
        header += "X-Content-Type-Options: nosniff\r\n"
        header += "\r\n"

        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func mimeType(for extension: String) -> String {
        switch `extension` {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "vrm", "vrma", "glb": return "model/gltf-binary"
        case "gltf": return "model/gltf+json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        default: return "application/octet-stream"
        }
    }
}