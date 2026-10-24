import Foundation
import AppKit
import CommonCrypto
import Network

/// ChatGPT/Codex **subscription** login — Swift port of codex-rs
/// `login/src/device_code_auth.rs` using its public OAuth client:
///   client_id  app_EMoamEEZ73f0CkXaXp7hrann
///   issuer     https://auth.openai.com
///   device     {issuer}/oauth/device/code → {issuer}/oauth/token
///   pkce       {issuer}/oauth/authorize → http://127.0.0.1:1455/auth/callback
///              (primary; opens the browser immediately — auth.openai.com sits
///              behind Cloudflare, which 403s plain HTTP clients but lets
///              browsers through, and the browser follows the user's proxy.
///              The redirect URI must match the codex CLI registration
///              exactly — `localhost` or a different path is rejected server-
///              side with `invalid_authorize_request`, leaving the user on an
///              OpenAI error page whose "Log in" link goes to chatgpt.com and
///              never calls back)
///   backend    https://chatgpt.com/backend-api/codex  (Responses wire)
enum CodexSubscription {

    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Refresh-token slot (secret, 0600 file) + non-secret expiry stamp.
    static let refreshSlot = "api-key.codex-refresh"
    static let expiryKey = "codex.token-expiry"
    static let issuer = "https://auth.openai.com"
    static let backendURL = "https://chatgpt.com/backend-api/codex"
    static let defaultModel = "gpt-5.2-codex"
    /// Same loopback redirect the codex CLI registers for its OAuth client —
    /// 127.0.0.1 (not localhost) and the /auth/callback path are both part of
    /// the exact-match registration; anything else is refused at /authorize.
    static let pkceCallbackPort: UInt16 = 1455
    static let pkceRedirectURI = "http://127.0.0.1:\(pkceCallbackPort)/auth/callback"
    static let userAgent = "moppet/1.0 (macOS; Codex-Brain)"

    enum LoginStep: Equatable {
        case pendingVerification(code: String, verificationURL: String)
        /// PKCE flow: browser just opened at the authorize page.
        case browserOpened(URL)
        case authenticated(account: String, expires: Date)
        case failed(String)
    }

    // MARK: - Device-code flow

    /// Session with snappy timeouts that also honors proxy env vars
    /// (HTTP_PROXY/HTTPS_PROXY/ALL_PROXY) — without this, users behind a
    /// regional proxy watched the login spinner hang for 60+ s because
    /// URLSession ignores those variables by default.
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 330
        var proxyDict: [String: Any] = [:]
        let env = ProcessInfo.processInfo.environment
        func proxyURL() -> URL? {
            for key in ["https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"] {
                if let raw = env[key], !raw.isEmpty, let url = URL(string: raw) {
                    return url
                }
            }
            return nil
        }
        if let proxy = proxyURL(), let host = proxy.host {
            // connectionProxyDictionary keys are the plain string names
            // (kCFStreamProperty* constants without the deprecation noise).
            for key in ["HTTPSProxyHost", "HTTPProxyHost"] { proxyDict[key] = host }
            if let port = proxy.port {
                for key in ["HTTPSProxyPort", "HTTPProxyPort"] { proxyDict[key] = port }
            }
        }
        if !proxyDict.isEmpty { config.connectionProxyDictionary = proxyDict }
        return URLSession(configuration: config)
    }()

    /// Starts the device flow; returns the user code + verification URL,
    /// then polls the token endpoint until authorized/expired. Honors task
    /// cancellation so the login UI can offer a working Cancel button.
    static func login(onStep: @escaping (LoginStep) -> Void) async {
        var request = URLRequest(url: URL(string: issuer + "/oauth/device/code")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.httpBody = Data(
            "client_id=\(clientID)&scope=openid%20profile%20email%20offline_access&audience=https%3A%2F%2Fapi.openai.com%2Fv1"
                .utf8)

        struct DeviceCodeResponse: Decodable {
            let deviceCode: String
            let userCode: String
            let verificationURI: String
            let expiresIn: Int
            enum CodingKeys: String, CodingKey {
                case deviceCode = "device_code"
                case userCode = "user_code"
                case verificationURI = "verification_uri"
                case expiresIn = "expires_in"
            }
        }

        let device: DeviceCodeResponse
        do {
            let (data, response) = try await session.data(for: request)
            if Task.isCancelled {
                onStep(.failed("cancelled"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                throw BrainError("device code request failed (no response)")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw BrainError(Self.describeFailure(
                    step: "device code request", status: http.statusCode, body: data))
            }
            device = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            onStep(.failed(error.localizedDescription))
            return
        }

        onStep(.pendingVerification(code: device.userCode, verificationURL: device.verificationURI))

        // Poll for authorization.
        let deadline = Date().addingTimeInterval(TimeInterval(min(device.expiresIn, 300)))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else {
                onStep(.failed("cancelled"))
                return
            }

            var poll = URLRequest(url: URL(string: issuer + "/oauth/token")!)
            poll.httpMethod = "POST"
            poll.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            poll.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            poll.timeoutInterval = 15
            poll.httpBody = Data(
                "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code&client_id=\(clientID)&device_code=\(device.deviceCode)"
                    .utf8)

            struct TokenResponse: Decodable {
                let accessToken: String?
                let idToken: String?
                let refreshToken: String?
                let error: String?
                let expiresIn: Int?
                enum CodingKeys: String, CodingKey {
                    case accessToken = "access_token"
                    case idToken = "id_token"
                    case refreshToken = "refresh_token"
                    case error
                    case expiresIn = "expires_in"
                }
            }

            guard let (data, _) = try? await session.data(for: poll),
                  !Task.isCancelled,
                  let token = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
                continue
            }
            if let accessToken = token.accessToken, !accessToken.isEmpty {
                Self.storeToken(accessToken: accessToken, idToken: token.idToken,
                                refreshToken: token.refreshToken,
                                expiresIn: token.expiresIn, onStep: onStep)
                return
            }
            if token.error == "authorization_pending" { continue }
            if token.error == "slow_down" {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            if let error = token.error, error == "expired_token" || error == "access_denied" {
                onStep(.failed(error))
                return
            }
        }
        onStep(.failed("login timed out"))
    }

    // MARK: - PKCE browser login (primary)

    /// Builds the browser authorize URL. The parameter set must stay an exact
    /// mirror of the codex CLI request for the same public OAuth client —
    /// OpenAI rejects the entire request server-side (`invalid_authorize_request`)
    /// when the redirect URI (exact-match registration) or other parameters
    /// drift, and the user then lands on an OpenAI error page that never
    /// calls back.
    static func buildAuthorizeURL(state: String, challenge: String) -> URL? {
        var components = URLComponents(string: issuer + "/oauth/authorize")!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: pkceRedirectURI),
            .init(name: "scope", value: "openid profile email offline_access api.connectors.read api.connectors.invoke"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        return components.url
    }

    // MARK: - Model catalog (fetched from the subscription backend)

    /// Models advertised by `GET {backend}/models` for this account. The
    /// bundled list below is only the offline fallback — the live catalog
    /// (persisted to UserDefaults) wins whenever one has been fetched, so new
    /// slugs appear without an app update.
    static let bundledModels = ["gpt-5.2-codex", "gpt-5.1-codex-max", "gpt-5.1-codex-mini", "gpt-5.2"]
    private static let catalogKey = "codex.model-catalog"

    static var modelCatalog: [String] {
        if let raw = UserDefaults.standard.data(forKey: catalogKey),
           let models = try? JSONDecoder().decode([String].self, from: raw),
           !models.isEmpty {
            return models
        }
        return bundledModels
    }

    /// Manual catalog override from the Settings editor (add/delete rows).
    /// The next API refresh replaces it — the backend list is the truth.
    static func setCatalog(_ models: [String]) {
        guard let raw = try? JSONEncoder().encode(models) else { return }
        UserDefaults.standard.set(raw, forKey: catalogKey)
        NotificationCenter.default.post(name: AIModelCatalog.changedNotification, object: nil)
    }

    private static var lastCatalogFetch = Date.distantPast

    /// Fetch the account's model slugs, persist them, and auto-correct a
    /// selected model the backend no longer offers. Throttled to once per
    /// 10 min (refreshModel fires on every settings change); silent on
    /// failure — the previous catalog (or the bundled list) keeps working.
    /// Fetch the account's model slugs, persist them, and auto-correct a
    /// selected model the backend no longer offers. Returns the fetched list
    /// (nil = skipped/throttled/failed — the previous catalog keeps working).
    /// The token the transports should use: the stored access token, or a
    /// freshly refreshed one when it has expired (or is about to).
    /// Falls back to the stored value — a failed refresh is not fatal, the
    /// request then surfaces the normal 401 guidance.
    static func validAccessToken() async -> String? {
        guard let stored = APIKeyStore.read(for: .codex), !stored.isEmpty else { return nil }
        let expiry = UserDefaults.standard.object(forKey: expiryKey) as? Date
        // Refresh 60s early; unknown expiry (legacy login) → use as-is.
        guard let expiry, expiry.timeIntervalSinceNow < 60 else { return stored }
        guard let refresh = APIKeyStore.read(slot: refreshSlot), !refresh.isEmpty else { return stored }

        var request = URLRequest(url: URL(string: issuer + "/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        request.httpBody = Data((
            "grant_type=refresh_token&client_id=\(clientID)"
            + "&refresh_token=\(refresh)"
        ).utf8)

        struct RefreshResponse: Decodable {
            let accessToken: String?
            let refreshToken: String?
            let expiresIn: Int?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case expiresIn = "expires_in"
            }
        }
        guard let (data, _) = try? await session.data(for: request),
              let response = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              let token = response.accessToken, !token.isEmpty else {
            return stored
        }
        APIKeyStore.write(token, for: .codex)
        if let rotated = response.refreshToken, !rotated.isEmpty {
            APIKeyStore.write(rotated, slot: refreshSlot)
        }
        let lifetime = response.expiresIn ?? 3600
        UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(lifetime)), forKey: expiryKey)
        return token
    }

    /// Throttled to once per 10 min (refreshModel fires on every settings
    /// change); silent on failure.
    @discardableResult
    static func refreshModels(force: Bool = false) async -> [String]? {
        guard force || Date().timeIntervalSince(lastCatalogFetch) > 600 else { return nil }
        lastCatalogFetch = Date()
        guard let token = APIKeyStore.read(for: .codex), !token.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: backendURL + "/models")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let models = parseModelCatalog(data), !models.isEmpty else { return nil }

        let changed = models != modelCatalog
        if let raw = try? JSONEncoder().encode(models) {
            UserDefaults.standard.set(raw, forKey: catalogKey)
        }
        let settings = AISettings.load()
        if settings.vendor == .codex, !models.contains(settings.model) {
            let corrected = models.first { $0.contains("codex") } ?? models[0]
            // refreshModels only runs in GUI contexts (login/refreshModel),
            // never in the headless CLI modes where the main thread blocks.
            await MainActor.run { AISettingsCoordinator.apply(model: corrected) }
        } else if changed {
            // Catalog changed but the selection is still valid — push the new
            // list into open pickers (ChatView re-derives on this notification).
            await MainActor.run { AISettingsCoordinator.broadcast(AISettings.load()) }
        }
        return models
    }

    /// Tolerant decoder: the catalog arrived as `{"items":[{"slug":…}]}` and
    /// `{"models":[…]}` shapes in the wild; accept slug/id keys at both the
    /// wrapper and item level.
    static func parseModelCatalog(_ data: Data) -> [String]? {
        func slugs(_ items: [[String: Any]]) -> [String] {
            items.compactMap { ($0["slug"] as? String) ?? ($0["id"] as? String) ?? ($0["model"] as? String) }
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["items", "models", "data"] {
                if let items = json[key] as? [[String: Any]], !slugs(items).isEmpty {
                    return slugs(items)
                }
                if let strings = json[key] as? [String], !strings.isEmpty {
                    return strings
                }
            }
        }
        if let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], !slugs(items).isEmpty {
            return slugs(items)
        }
        if let strings = try? JSONSerialization.jsonObject(with: data) as? [String], !strings.isEmpty {
            return strings
        }
        return nil
    }

    /// `--probe-models`: dump the live catalog response (status + raw body)
    /// to stderr and exit — diagnostics for the subscription backend.
    static func probeModels() -> Never {
        guard let token = APIKeyStore.read(for: .codex), !token.isEmpty else {
            FileHandle.standardError.write(Data("probe-models: no codex token in the keychain — sign in via Settings first\n".utf8))
            exit(2)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var output = ""
        Task {
            var request = URLRequest(url: URL(string: backendURL + "/models")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                output = "HTTP \(status)\n\(String(data: data, encoding: .utf8) ?? "<binary>")"
            } catch {
                output = "ERROR: \(error.localizedDescription)"
            }
            semaphore.signal()
        }
        semaphore.wait()
        FileHandle.standardError.write(Data("probe-models: \(output.prefix(4000))\n".utf8))
        exit(0)
    }

    /// Browser-first login: opens `authorize` with a PKCE challenge right
    /// away, catches the redirect on a loopback listener, exchanges the code.
    /// This is the flow that works behind Cloudflare / regional proxies,
    /// because the auth dance happens in the user's browser.
    static func loginPKCE(onStep: @escaping (LoginStep) -> Void) async {
        // 1. PKCE material.
        var raw = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        let verifier = Data(raw).base64URLEnced()
        let challenge = sha256Base64URL(verifier)
        let state = UUID().uuidString

        // 2. Loopback redirect listener.
        let listener = LoopbackCallbackListener()
        guard await listener.start(port: pkceCallbackPort) else {
            onStep(.failed("cannot listen on 127.0.0.1:\(pkceCallbackPort) — try device code"))
            return
        }

        // 3. Open the browser immediately (the click the user expects).
        guard let authorizeURL = buildAuthorizeURL(state: state, challenge: challenge) else {
            onStep(.failed("failed to build authorize URL"))
            return
        }
        _ = await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
        onStep(.browserOpened(authorizeURL))

        // 4. Wait for the redirect (5 min) or cancellation.
        let callback: (code: String, state: String?)? = await withTaskGroup(
            of: (code: String, state: String?)?.self
        ) { group in
            group.addTask { await listener.awaitCode() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            listener.stop()        // resumes a still-parked awaitCode with nil
            // On the success path the remaining child is the 300s sleep —
            // `next()` would wait it out before the token exchange (observed:
            // browser showed "Login captured" while the app sat "Waiting…" for
            // five minutes). Cancel it so the drain returns immediately.
            group.cancelAll()
            _ = await group.next() // drain
            return first
        }
        guard !Task.isCancelled else {
            onStep(.failed("cancelled"))
            return
        }
        guard let callback else {
            onStep(.failed("browser login timed out (no callback on 127.0.0.1:\(pkceCallbackPort))"))
            return
        }
        guard callback.state == state else {
            onStep(.failed("state mismatch — possible CSRF, aborted"))
            return
        }

        // 5. Exchange the code for tokens.
        var exchange = URLRequest(url: URL(string: issuer + "/oauth/token")!)
        exchange.httpMethod = "POST"
        exchange.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        exchange.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        exchange.timeoutInterval = 20
        exchange.httpBody = Data((
            "grant_type=authorization_code&client_id=\(clientID)"
            + "&redirect_uri=\(pkceRedirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
            + "&code=\(callback.code)&code_verifier=\(verifier)"
        ).utf8)

        struct TokenResponse: Decodable {
            let accessToken: String?
            let idToken: String?
            let refreshToken: String?
            let error: String?
            let errorDescription: String?
            let expiresIn: Int?
            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case idToken = "id_token"
                case refreshToken = "refresh_token"
                case error
                case errorDescription = "error_description"
                case expiresIn = "expires_in"
            }
        }

        do {
            let (data, response) = try await session.data(for: exchange)
            if Task.isCancelled {
                onStep(.failed("cancelled"))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                throw BrainError("token exchange failed (no response)")
            }
            let token = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let accessToken = token.accessToken, !accessToken.isEmpty {
                storeToken(accessToken: accessToken, idToken: token.idToken,
                           refreshToken: token.refreshToken,
                           expiresIn: token.expiresIn, onStep: onStep)
                return
            }
            throw BrainError(describeFailure(
                step: "token exchange", status: http.statusCode, body: data,
                oauthError: token.error ?? token.errorDescription))
        } catch {
            onStep(.failed(error.localizedDescription))
        }
    }

    // MARK: - Shared helpers

    /// Persist the access token like any API key and switch the vendor.
    /// The refresh token (scope offline_access) and expiry are kept so the
    /// session survives past the access token's ~1h lifetime instead of
    /// 401-ing until the user redoes the browser login.
    private static func storeToken(accessToken: String, idToken: String?,
                                   refreshToken: String? = nil,
                                   expiresIn: Int?, onStep: @escaping (LoginStep) -> Void) {
        APIKeyStore.write(accessToken, for: .codex)
        if let refreshToken, !refreshToken.isEmpty {
            APIKeyStore.write(refreshToken, slot: refreshSlot)
        }
        if let expiresIn {
            UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(expiresIn)),
                                      forKey: expiryKey)
        }
        var settings = AISettings.load()
        settings.vendor = .codex
        // A subscription login must NOT write through an active custom
        // profile's key slot — save() would park the OAuth token in
        // api-key.profile:<id>, clobbering that profile's real API key and
        // later sending the ChatGPT token to the profile's endpoint.
        settings.activeProfileID = nil
        settings.baseURL = backendURL
        settings.model = settings.model.isEmpty ? defaultModel : settings.model
        settings.apiKey = accessToken
        settings.save()

        let account = accountFromIDToken(idToken) ?? "ChatGPT plan"
        let expires = Date().addingTimeInterval(TimeInterval(expiresIn ?? 3600))
        onStep(.authenticated(account: account, expires: expires))
        // Fresh token → pull the account's real model catalog right away so
        // the picker switches from the bundled fallback to the live list.
        Task { await refreshModels(force: true) }
    }

    /// Pull the email out of an id_token JWT payload for the "signed in as …"
    /// line (no verification — it came straight from the token endpoint).
    private static func accountFromIDToken(_ idToken: String?) -> String? {
        guard let idToken else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2,
              let payload = Data(base64URLEncoded: String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let email = json["email"] as? String else { return nil }
        return email
    }

    /// Human-readable OAuth failure: status + a Cloudflare/proxy hint when the
    /// body is a challenge page instead of an API error.
    static func describeFailure(step: String, status: Int, body: Data, oauthError: String? = nil) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""
        if let oauthError, !oauthError.isEmpty {
            return "\(step) failed HTTP \(status): \(oauthError)"
        }
        if text.contains("Just a moment") || text.contains("cf-challenge") {
            return "\(step) failed HTTP \(status) — blocked by Cloudflare; use the browser login or a proxy"
        }
        let snippet = text.prefix(160).replacingOccurrences(of: "\n", with: " ")
        return "\(step) failed HTTP \(status)\(snippet.isEmpty ? "" : ": \(snippet)")"
    }

    private static func sha256Base64URL(_ input: String) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64URLEnced()
    }

    // MARK: - Loopback redirect listener

/// One-shot localhost HTTP listener for the OAuth redirect
/// (`http://127.0.0.1:1455/auth/callback`), mirroring the codex CLI loopback.
/// Accepts any request path and hands the `code`/`state` query to the PKCE flow.
/// One-shot resume guard for the bind continuation: the NWListener state
/// handler can fire again (`.cancelled` after stop) and the startup timeout
/// races it, but the continuation must be resumed exactly once. `@unchecked
/// Sendable` because the NSLock makes the flag access safe across the
/// listener queue and the timeout closure.
private final class BindSettler: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ result: Bool, _ cont: CheckedContinuation<Bool, Never>) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { cont.resume(returning: result) }
    }
}

private final class LoopbackCallbackListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "moppet.oauth.callback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<(code: String, state: String?)?, Never>?
    private var delivered = false

    /// Binds the port and waits for the real bind outcome. `NWListener.start`
    /// reports success/failure asynchronously through `stateUpdateHandler`, so
    /// a plain `try? NWListener(...)` would return true even when the port is
    /// already taken — the redirect would then hit whatever else owns the
    /// port and login would hang forever with no error shown.
    func start(port: UInt16) async -> Bool {
        guard port != 0, let endpoint = NWEndpoint.Port(rawValue: port) else { return false }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters, on: endpoint) else { return false }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener

        // The state handler fires again on later .cancelled (when we stop the
        // listener), so resume the continuation exactly once. A lock-guarded
        // box (not a captured local var) keeps the handler/timeout closures
        // Sendable-clean.
        let once = BindSettler()

        let bound = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(true, cont)
                case .failed, .cancelled: once.resume(false, cont)
                default: break
                }
            }
            // Safety net: if the state handler never settles, fail the start
            // so the login UI reports an error instead of hanging.
            queue.asyncAfter(deadline: .now() + 2) { once.resume(false, cont) }
            listener.start(queue: queue)
        }
        if !bound {
            listener.stateUpdateHandler = nil
            listener.cancel()
            self.listener = nil
        }
        return bound
    }

    func awaitCode() async -> (code: String, state: String?)? {
        await withCheckedContinuation { cont in
            queue.async {
                if self.delivered {
                    cont.resume(returning: nil)
                } else {
                    self.continuation = cont
                }
            }
        }
    }

    /// Stop the listener; a pending awaitCode resumes with nil.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            if let cont = self.continuation {
                self.continuation = nil
                self.delivered = true
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: - Connection handling (single GET, minimal HTTP/1.0 reply)

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self]
            data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
                self.handleRequest(request, connection: connection)
                return
            }
            if error == nil && !isComplete {
                self.receive(connection: connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func handleRequest(_ request: String, connection: NWConnection) {
        defer { connection.cancel() }
        let html = """
        HTTP/1.0 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Connection: close\r
        \r
        <html><body style="font-family:-apple-system;text-align:center;padding-top:3cm">\
        ✅ Login captured — you can return to Moppet.\
        <script>setTimeout(function(){window.close()},1500)</script></body></html>
        """
        connection.send(content: Data(html.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })

        // GET /callback?code=…&state=… HTTP/1.1
        guard let requestLine = request.split(separator: "\r\n").first.map(String.init),
              let queryStart = requestLine.firstIndex(of: "?"),
              let spaceAfterQuery = requestLine[queryStart...].firstIndex(of: " ") else { return }
        let query = String(requestLine[requestLine.index(after: queryStart)..<spaceAfterQuery])
        guard let components = URLComponents(string: "http://localhost/callback?\(query)") else { return }
        let items = components.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else { return }
        let state = items.first(where: { $0.name == "state" })?.value
        queue.async {
            guard !self.delivered, let cont = self.continuation else { return }
            self.delivered = true
            self.continuation = nil
            cont.resume(returning: (code, state))
            self.listener?.cancel()
            self.listener = nil
        }
    }
}

    // MARK: - Responses wire transport (subscription backend only)

    /// The ChatGPT codex backend speaks the Responses API only, so this
    /// vendor gets a dedicated BrainModel transport; every other vendor stays
    /// on swift-ai-sdk.
    struct ResponsesModel: BrainModel {
        let accessToken: String
        let model: String
        /// codex hosted web_search — appended to the request as a native
        /// `{"type":"web_search"}` tool executed server-side (upstream
        /// hosted_spec.rs create_web_search_tool).
        var webSearch: Bool = false

        func streamTurn(system: String, developer: String,
                        history: [BrainResponseItem],
                        specs: [BrainTools.Spec]) async throws -> AsyncThrowingStream<BrainStreamEvent, Error> {
            var request = URLRequest(url: URL(string: backendURL + "/responses")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // Live token: a refresh token rotation or a new login updates the
            // store, but this struct was built earlier with the old value.
            let liveToken = APIKeyStore.read(for: .codex) ?? accessToken
            request.setValue("Bearer \(liveToken)", forHTTPHeaderField: "Authorization")
            request.setValue("originator: moppet", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
            request.timeoutInterval = 300

            func encodeItem(_ item: BrainResponseItem) -> [[String: Any]] {
                switch item {
                case .message(let role, let content):
                    return [["type": "message", "role": role,
                             "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": content]]]]
                case .reasoning(let summary):
                    return [["type": "reasoning", "summary": [["type": "summary_text", "text": summary]]]]
                case .functionCall(let callID, let name, let arguments):
                    return [["type": "function_call", "call_id": callID, "name": name, "arguments": arguments]]
                case .functionCallOutput(let callID, let output):
                    return [["type": "function_call_output", "call_id": callID, "output": output]]
                case .plan:
                    return [["type": "message", "role": "assistant",
                             "content": [["type": "output_text", "text": "(plan updated)"]]]]
                case .imageItem(let callID, let dataURL):
                    // Images enter as user-role input_image content (codex
                    // ImageViewItem / UserInput::Image wire shape).
                    let note = callID == "user" ? "user-attached image" : "image for tool call \(callID)"
                    return [["type": "message", "role": "user",
                             "content": [
                                ["type": "input_text", "text": note],
                                ["type": "input_image", "image_url": dataURL],
                             ]]]
                }
            }

            var tools: [[String: Any]] = specs.map { spec in
                ["type": "function", "name": spec.name,
                 "description": spec.description,
                 "parameters": spec.parametersJSONSchema,
                 "strict": false] as [String: Any]
            }
            if webSearch {
                tools.append(["type": "web_search"])
            }

            var input: [[String: Any]] = [encodeItem(.message(role: "developer", content: developer))[0]]
            for item in history {
                input.append(contentsOf: encodeItem(item))
            }

            let body: [String: Any] = [
                "model": model,
                "instructions": system,
                "input": input,
                "tools": tools,
                "tool_choice": "auto",
                "stream": true,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var errorText = ""
                for try await line in bytes.lines {
                    errorText += line
                    if errorText.count > 500 { break }
                }
                if http.statusCode == 401 {
                    throw BrainError("codex backend 401: token missing or expired — sign in via Settings → Codex Subscription (ChatGPT plan), or switch provider")
                }
                throw BrainError("codex backend \(http.statusCode): \(errorText.prefix(300))")
            }

            return AsyncThrowingStream { (continuation: AsyncThrowingStream<BrainStreamEvent, Error>.Continuation) in
                let task = Task {
                    var callID: String?
                    var name: String?
                    var arguments = ""
                    var usage: BrainUsage?

                    func flush() {
                        if let callID, let name {
                            continuation.yield(.toolCall(BrainToolCall(
                                callID: callID, name: name,
                                argumentsJSON: arguments.isEmpty ? "{}" : arguments)))
                        }
                        callID = nil; name = nil; arguments = ""
                    }

                    do {
                        for try await raw in bytes.lines {
                            guard raw.hasPrefix("data: "), raw != "data: [DONE]" else { continue }
                            guard let data = String(raw.dropFirst(6)).data(using: .utf8),
                                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  let type = event["type"] as? String else { continue }
                            switch type {
                            case "response.output_text.delta":
                                if let delta = event["delta"] as? String {
                                    continuation.yield(.textDelta(delta))
                                }
                            case "response.function_call_arguments.delta":
                                arguments += (event["delta"] as? String) ?? ""
                            case "response.output_item.done":
                                if let item = event["item"] as? [String: Any],
                                   (item["type"] as? String) == "function_call" {
                                    callID = (item["call_id"] as? String) ?? callID
                                    name = (item["name"] as? String) ?? name
                                    arguments = (item["arguments"] as? String) ?? arguments
                                    flush()
                                }
                            case "response.completed":
                                if let resp = event["response"] as? [String: Any],
                                   let u = resp["usage"] as? [String: Any] {
                                    usage = BrainUsage(inputTokens: u["input_tokens"] as? Int ?? 0,
                                                       outputTokens: u["output_tokens"] as? Int ?? 0)
                                }
                            default:
                                break
                            }
                        }
                        flush()
                        continuation.yield(.completed(finalMessage: nil, usage: usage))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
}

private extension Data {
    /// base64url without padding (RFC 7636 PKCE encoding).
    func base64URLEnced() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
