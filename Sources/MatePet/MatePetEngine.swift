import AppKit
import WebKit

/// The MatePet renderer: owns the WKWebView, the loopback asset server and the
/// JS command queue. It has no knowledge of Moppet's `PetBus`, Brain or window
/// layout — the host feeds it state and user intent through the small public
/// API below and listens to `onEvent`.
@MainActor
public final class MatePetEngine: NSObject, MatePetRendering {

    public private(set) var webView: WKWebView
    public private(set) var isPageReady = false
    public private(set) var isModelReady = false

    /// All page events are delivered here on the main actor.
    public var onEvent: ((MatePetEvent) -> Void)?
    /// One-shot PNG bytes requested by `captureSnapshot()`. Used by the
    /// offscreen character probe (WKWebView.takeSnapshot cannot capture a
    /// transparent WebGL surface reliably, but canvas.toDataURL can).
    public var onSnapshot: ((Data?) -> Void)?

    private static let verbose = ProcessInfo.processInfo.environment["MOPPET_MATE_PET_DEV"] != nil
    private var server: MatePetAssetServer?
    private var didStart = false
    private var pendingCommands: [String] = []
    private static let maxPendingCommands = 120

    public override init() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false

        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 230, height: 270),
                            configuration: configuration)
        super.init()

        // WKWebView draws an opaque page background by default. The pet panel is
        // transparent, so the web view must be too. `underPageBackgroundColor`
        // is public but insufficient on its own; `drawsBackground` is the
        // documented-by-community switch every transparent WKWebView uses.
        // If this ever ships to the App Store, revisit with a custom
        // WKURLSchemeHandler + an NSView-level compositing workaround.
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        webView.allowsBackForwardNavigationGestures = false
        webView.navigationDelegate = self
        if Self.verbose {
            webView.isInspectable = true
            webView.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }

        webView.configuration.userContentController.add(self, name: "matePet")
    }

    public func startIfNeeded() {
        startIfNeeded(probeMode: false)
    }

    /// Starts the asset server once and loads the pet page. Safe to call from
    /// every `makeNSView`; only the first call does work.
    public func startIfNeeded(probeMode: Bool = false,
                              probeState: String? = nil,
                              probeChibi: Bool = false) {
        guard !didStart else { return }
        didStart = true
        debug("startIfNeeded")

        guard let bundleRoot = Bundle.module.resourceURL else {
            emit(.loadError("MatePet resource bundle is missing"))
            return
        }
        let resources = bundleRoot.appendingPathComponent("Resources", isDirectory: true)
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("mate-pet.html").path) else {
            emit(.loadError("mate-pet.html is missing from the resource bundle"))
            return
        }

        debug("resources=\(resources.path)")
        let server = MatePetAssetServer(root: resources)
        self.server = server
        server.start { [weak self] port in
            guard let self else { return }
            var query = probeMode ? ["probe=1"] : []
            if let probeState, !probeState.isEmpty { query.append("state=\(probeState)") }
            if probeChibi || MatePetSettings.chibi { query.append("chibi=1") }
            if MatePetSettings.muted { query.append("muted=1") }
            let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
            guard let url = URL(string: "http://127.0.0.1:\(port)/mate-pet.html\(suffix)") else {
                self.emit(.loadError("could not build the pet page URL"))
                return
            }
            self.debug("loading \(url.absoluteString)")
            self.webView.load(URLRequest(url: url,
                                         cachePolicy: .reloadIgnoringLocalCacheData,
                                         timeoutInterval: 20))
        } onError: { [weak self] message in
            self?.emit(.loadError(message))
        }

        // If the page never even reaches DOM ready, reveal the panel with an
        // error instead of leaving an invisible floater on screen forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, !self.isPageReady else { return }
            self.emit(.loadError("the pet page did not become ready"))
        }
    }

    public func stop() {
        server?.stop()
        server = nil
        didStart = false
    }

    // MARK: - Commands

    public func setState(_ state: MatePetState) {
        send("setState", value: state.rawValue)
    }

    public func setTalking(_ talking: Bool) {
        send("setTalking", value: talking)
    }

    public func say(_ text: String, seconds: Double? = nil) {
        var payload: [String: Any] = ["text": text]
        if let seconds { payload["seconds"] = seconds }
        send("say", value: payload)
    }

    public func look(atNormalizedX x: Double, y: Double) {
        send("look", value: ["x": max(0, min(1, x)), "y": max(0, min(1, y))])
    }

    public func dragBegan() {
        send("dragBegan")
    }

    public func dragMoved(dx: Double, dy: Double) {
        send("dragMoved", value: ["dx": dx, "dy": dy])
    }

    public func dragEnded(vx: Double, vy: Double) {
        send("dragEnded", value: ["vx": vx, "vy": vy])
    }

    public func poke(region: MatePetHitRegion, count: Int = 1) {
        send("poke", value: ["region": region.rawValue, "count": count])
    }

    public func play(_ action: MatePetAction) {
        send("play", value: action.rawValue)
    }

    public func setChibi(_ on: Bool) {
        MatePetSettings.chibi = on
        send("setChibi", value: on)
    }

    /// -1 = left, 0 = stop, +1 = right. The host moves the actual NSPanel; the
    /// page only animates the legs/arms and footsteps.
    public func setWalking(_ direction: Int) {
        send("setWalking", value: max(-1, min(1, direction)))
    }

    public func setMuted(_ muted: Bool) {
        MatePetSettings.muted = muted
        send("setMuted", value: muted)
    }

    public func setPaused(_ paused: Bool) {
        send("setPaused", value: paused)
    }

    /// AudioContext can only start after a user gesture. The interaction view
    /// calls this on mouse-down so poke/pet sounds are audible immediately.
    public func audioUnlock() {
        send("audioUnlock")
    }

    public func captureSnapshot() {
        send("capture")
    }

    public func syncPreferences() {
        send("setMuted", value: MatePetSettings.muted)
        // Silent so a saved Chibi preference does not chirp on every launch.
        send("setChibi", value: ["on": MatePetSettings.chibi, "silent": true])
    }

    private func debug(_ message: String) {
        guard Self.verbose else { return }
        FileHandle.standardError.write(Data("mate-pet: \(message)\n".utf8))
    }

    private func send(_ command: String, value: Any? = nil) {
        var payload: [String: Any] = ["cmd": command]
        if let value { payload["value"] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = "window.matePet && window.matePet.receive(\(json));"
        guard isPageReady else {
            if pendingCommands.count >= Self.maxPendingCommands {
                pendingCommands.removeFirst()
            }
            pendingCommands.append(script)
            return
        }
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                FileHandle.standardError.write(
                    Data("mate-pet: JS command \(command) failed: \(error.localizedDescription)\n".utf8))
            } else if Self.verbose {
                FileHandle.standardError.write(
                    Data("mate-pet: JS command \(command) ok\n".utf8))
            }
        }
    }

    private func flushPendingCommands() {
        guard !pendingCommands.isEmpty else { return }
        let commands = pendingCommands
        pendingCommands.removeAll(keepingCapacity: true)
        for script in commands {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
    }

    private func emit(_ event: MatePetEvent) {
        onEvent?(event)
    }

    fileprivate func handleMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else { return }

        switch type {
        case "ready":
            guard !isPageReady else { return }
            debug("page ready")
            isPageReady = true
            flushPendingCommands()
            emit(.ready)
        case "modelReady":
            debug("model ready")
            isModelReady = true
            emit(.modelReady)
        case "error":
            let message = dict["message"] as? String ?? "unknown MatePet error"
            FileHandle.standardError.write(Data("mate-pet error: \(message)\n".utf8))
            emit(.loadError(message))
        case "log":
            let message = dict["message"] as? String ?? ""
            debug("page: \(message)")
            emit(.log(message))
        case "hideFinished":
            emit(.hideFinished)
        case "petted":
            emit(.petted(count: dict["count"] as? Int ?? 1))
        case "snapshot":
            let base64 = dict["data"] as? String ?? ""
            debug("snapshot chars=\(base64.count)")
            let data = Data(base64Encoded: base64)
            onSnapshot?(data)
        default:
            break
        }
    }
}

// MARK: - JS bridge

extension MatePetEngine: WKScriptMessageHandler {
    public nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // WKWebView delivers script messages on the main thread, but the
        // protocol requirement is nonisolated. Pin the hop explicitly.
        let body: Any = MainActor.assumeIsolated { message.body }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.handleMessage(body)
            }
        }
    }
}

// MARK: - Navigation failures

extension MatePetEngine: WKNavigationDelegate {
    public nonisolated func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.emit(.loadError(message))
            }
        }
    }

    public nonisolated func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.emit(.loadError(message))
            }
        }
    }
}