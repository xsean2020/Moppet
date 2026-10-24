import Foundation
import Observation
import KeychainAccess
import SwiftAISDK
import AISDKProvider
import AISDKProviderUtils
import OpenAIProvider
import OpenAICompatibleProvider
import AnthropicProvider
import GoogleProvider
import DeepSeekProvider
import GroqProvider
import MistralProvider
import OpenResponsesProvider

// MARK: - Vendor model

/// Supported AI vendors. Native provider modules from swift-ai-sdk for the
/// big five, and an OpenAI-compatible transport for everything else
/// (Zhipu GLM, Moonshot, Ollama, LM Studio, vLLM, …).
enum AIVendor: String, CaseIterable, Codable, Identifiable {
    case codex = "codex"
    case glm = "glm"
    case openai = "openai"
    case anthropic = "anthropic"
    case google = "google"
    case deepseek = "deepseek"
    case groq = "groq"
    case mistral = "mistral"
    case ollama = "ollama"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex (ChatGPT subscription)"
        case .glm: "Zhipu GLM (OpenAI-compatible)"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Google Gemini"
        case .deepseek: "DeepSeek"
        case .groq: "Groq"
        case .mistral: "Mistral"
        case .ollama: "Ollama (local)"
        case .custom: "Custom OpenAI-compatible"
        }
    }

    var defaultBaseURL: String? {
        switch self {
        case .codex: CodexSubscription.backendURL
        case .glm: "https://open.bigmodel.cn/api/paas/v4"
        case .ollama: "http://127.0.0.1:11434/v1"
        case .custom: nil
        default: nil    // native providers know their endpoint
        }
    }

    var defaultModel: String {
        switch self {
        case .codex: CodexSubscription.defaultModel
        case .glm: "glm-4.6"
        case .openai: "gpt-4o"
        case .anthropic: "claude-sonnet-4-5"
        case .google: "gemini-2.0-flash"
        case .deepseek: "deepseek-chat"
        case .groq: "llama-3.3-70b-versatile"
        case .mistral: "mistral-large-latest"
        case .ollama: "qwen2.5:7b"
        case .custom: ""
        }
    }

    /// Compact display name for inline pickers (chat window / quick panel).
    var shortName: String {
        switch self {
        case .codex: "Codex"
        case .glm: "GLM"
        case .openai: "OpenAI"
        case .anthropic: "Anthropic"
        case .google: "Gemini"
        case .deepseek: "DeepSeek"
        case .groq: "Groq"
        case .mistral: "Mistral"
        case .ollama: "Ollama"
        case .custom: "Custom"
        }
    }

    /// Curated model menu per provider (default model first). Empty for
    /// free-form vendors (Ollama/custom) — those keep a text field.
    /// Custom model IDs typed by the user always appear as an extra row.
    var knownModels: [String] {
        switch self {
        // Codex menu = the account's live catalog from the subscription
        // backend (persisted by refreshModels); bundled list is the offline
        // fallback so the picker is never empty before the first fetch.
        case .codex: CodexSubscription.modelCatalog
        case .glm: ["glm-4.6", "glm-4.5", "glm-4.5-air", "glm-4.5-flash", "glm-4-flash"]
        case .openai: ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "o4-mini"]
        case .anthropic: ["claude-sonnet-4-5", "claude-opus-4-1", "claude-haiku-4-5"]
        case .google: ["gemini-2.0-flash", "gemini-2.5-pro", "gemini-2.0-flash-lite"]
        case .deepseek: ["deepseek-chat", "deepseek-reasoner"]
        case .groq: ["llama-3.3-70b-versatile", "llama-3.1-8b-instant", "moonshotai/kimi-k2-instruct"]
        case .mistral: ["mistral-large-latest", "mistral-small-latest", "magistral-small-latest"]
        case .ollama, .custom: []
        }
    }

    var needsAPIKey: Bool {
        self != .ollama
    }

    /// Subscription backend speaks Responses-only → dedicated transport.
    var usesCodexResponsesTransport: Bool { self == .codex }

    /// Uses the native swift-ai-sdk provider (chat-completions style).
    var usesNativeProvider: Bool {
        switch self {
        case .openai, .anthropic, .google, .deepseek, .groq, .mistral: true
        default: false
        }
    }
}

// MARK: - Settings

struct AISettings: Codable, Equatable {
    var vendor: AIVendor = .glm
    var baseURL: String = AIVendor.glm.defaultBaseURL ?? ""
    var model: String = AIVendor.glm.defaultModel
    var apiKey: String = ""
    /// Active ZCode-style custom provider (see AIProviders.swift). Optional
    /// decodes as nil in pre-profile payloads. While set, transport goes
    /// through the profile's OpenAI-compatible endpoint.
    var activeProfileID: String?

    var isConfigured: Bool {
        if activeProfile != nil {
            // Profile transport: base URL + model required; local servers
            // (vLLM/LM Studio/Ollama bridges) run without keys.
            return !baseURL.isEmpty && !model.isEmpty
        }
        if vendor.needsAPIKey && apiKey.isEmpty { return false }
        if !vendor.usesNativeProvider && baseURL.isEmpty { return false }
        return !model.isEmpty
    }

    static let storageKey = "ai-settings"
    static let keychainService = "cc.cleaner.ai"

    static func load() -> AISettings {
        var settings = AISettings()
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AISettings.self, from: data) {
            settings = decoded
        }
        APIKeyStore.migrateLegacyKey(to: settings.vendor)
        // Profile-active settings must read the PROFILE key slot. Reading the
        // builtin vendor slot here (`.custom`, usually empty) used to wipe the
        // profile key from memory on every load — it worked right after
        // switching (selectProfile loads the right slot) and then silently
        // lost the key on the next AISettings.load() anywhere in the app.
        if let profileID = settings.activeProfileID,
           AIProviderRegistry.profile(id: profileID) != nil {
            settings.apiKey = APIKeyStore.read(slot: AIProviderProfileKey(profileID)) ?? ""
        } else {
            settings.activeProfileID = nil   // stale id (profile deleted)
            settings.apiKey = APIKeyStore.read(for: settings.vendor) ?? ""
        }
        return settings
    }

    /// Provider→model cascade shared by Settings, the chat window and the
    /// quick panel: switching vendor applies its default baseURL, picks
    /// its default model unless the current model is already one of its
    /// known models (free-form vendors reset to their default), and pulls
    /// the key stored for THAT vendor (each vendor keeps its own).
    mutating func switchVendor(to newVendor: AIVendor) {
        activeProfileID = nil            // builtin selection drops any profile
        vendor = newVendor
        baseURL = newVendor.defaultBaseURL ?? ""
        if !AIModelCatalog.models(for: newVendor).contains(model) {
            model = newVendor.defaultModel
        }
        apiKey = APIKeyStore.read(for: newVendor) ?? ""
    }

    func save() {
        var storable = self
        storable.apiKey = ""
        if let data = try? JSONEncoder().encode(storable) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        // A profile's key must NEVER land in a builtin vendor slot — that is
        // exactly the cross-vendor contamination the per-vendor slots fixed.
        if let profileID = activeProfileID {
            let key = AIProviderProfileKey(profileID)
            if apiKey.isEmpty {
                APIKeyStore.delete(slot: key)
            } else {
                APIKeyStore.write(apiKey, slot: key)
            }
            return
        }
        if apiKey.isEmpty {
            APIKeyStore.delete(for: vendor)
        } else {
            APIKeyStore.write(apiKey, for: vendor)
        }
    }
}

// MARK: - API key storage (0600 file; keychain = one-time legacy source)

/// Credential slots for every vendor and custom provider profile. The
/// PRIMARY store is `~/.moppet/ai-keys.json` with 0600 permissions — NOT
/// the macOS keychain.
///
/// Why: the keychain ACL dialog ("wants to use your confidential
/// information stored in cc.cleaner.ai") is not a bug we can code around.
/// An item only trusts the binary that wrote it; this unsigned SPM binary
/// gets a fresh ad-hoc signature on every `swift build`, so the first
/// read after EVERY rebuild prompted for the Mac password — worst case a
/// dialog per slot. Files have no ACL: zero prompts, forever, across
/// rebuilds. This is the same trade the codex CLI makes (`~/.codex/auth.json`
/// holds its OAuth token in plaintext). Trade-off: any process running as
/// this user can read the file — acceptable for a local tool; revisit if
/// the app is ever properly signed/notarized (debt #8), at which point the
/// keychain stops prompting legitimately.
///
/// Slots mirror the old keychain keys exactly (`api-key.<vendor>`,
/// `api-key.profile:<id>`, legacy `api-key`), so selection logic is
/// unchanged. Items still sitting in the real keychain migrate lazily: the
/// first read of a missing slot falls back to the keychain ONCE, copies the
/// value into the file, and deletes the keychain item — after which that
/// slot never prompts again.
enum APIKeyStore {

    static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("ai-keys.json")
    }

    private static let lock = NSLock()
    /// In-memory mirror of the file; the file is read once per process.
    private static var store: [String: String]?
    /// Keychain is ONLY consulted for legacy migration (one prompt per
    /// pre-existing slot, then the item is deleted).
    private static var keychain = Keychain(service: AISettings.keychainService)
    /// The pre-multi-vendor build's single global entry.
    private static let legacyKey = "api-key"

    private static func accountKey(_ vendor: AIVendor) -> String {
        "api-key.\(vendor.rawValue)"
    }

    // MARK: file store

    /// Caller must hold `lock`.
    private static func loadStoreUnlocked() -> [String: String] {
        if let store { return store }
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            store = decoded
        } else {
            store = [:]
        }
        return store!
    }

    /// Caller must hold `lock`. Atomic write + chmod 0600 (creator-owned
    /// read/write only — the whole security story of the file store).
    private static func persistStoreUnlocked(_ updated: [String: String]) {
        store = updated
        guard let data = try? JSONEncoder().encode(updated) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Caller must hold `lock`. File first; a hit in the legacy keychain is
    /// migrated into the file and removed from the keychain so the slot
    /// never prompts again (the SecItem read is the ONE prompt this slot
    /// will ever cost).
    private static func readSlotUnlocked(_ key: String) -> String? {
        let fileStore = loadStoreUnlocked()
        if let value = fileStore[key] {
            return value.isEmpty ? nil : value
        }
        if let legacy = try? keychain.get(key), !legacy.isEmpty {
            persistStoreUnlocked([key: legacy].merging(fileStore) { current, _ in current })
            try? keychain.remove(key)
            return legacy
        }
        return nil
    }

    // MARK: raw-slot API (vendors + provider profiles)

    static func write(_ value: String, slot key: String) {
        lock.lock()
        defer { lock.unlock() }
        persistStoreUnlocked(loadStoreUnlocked().merging([key: value]) { _, new in new })
    }

    static func read(slot key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return readSlotUnlocked(key)
    }

    static func delete(slot key: String) {
        lock.lock()
        defer { lock.unlock() }
        persistStoreUnlocked(loadStoreUnlocked().filter { $0.key != key })
        // Best effort: also clear a pre-migration keychain item (delete
        // never prompts).
        try? keychain.remove(key)
    }

    // MARK: vendor convenience

    static func write(_ value: String, for vendor: AIVendor) {
        write(value, slot: accountKey(vendor))
    }

    static func read(for vendor: AIVendor) -> String? {
        read(slot: accountKey(vendor))
    }

    static func delete(for vendor: AIVendor) {
        delete(slot: accountKey(vendor))
    }

    /// One-time migration of the pre-multi-vendor build's single global key
    /// into the CURRENT vendor's slot. Without the removal, every fresh
    /// vendor would inherit the old key and repeat the cross-vendor
    /// contamination this split fixes. Runs once per process, before the
    /// first per-vendor read.
    static func migrateLegacyKey(to vendor: AIVendor) {
        lock.lock()
        defer { lock.unlock() }
        guard !migrated else { return }
        migrated = true
        guard let legacy = readSlotUnlocked(legacyKey), !legacy.isEmpty else { return }
        let key = accountKey(vendor)
        if (readSlotUnlocked(key) ?? "").isEmpty {
            persistStoreUnlocked(loadStoreUnlocked().merging([key: legacy]) { _, new in new })
        }
        persistStoreUnlocked(loadStoreUnlocked().filter { $0.key != legacyKey })
        try? keychain.remove(legacyKey)
    }

    private static var migrated = false
}

// MARK: - Provider/model switching coordination

/// Central vendor/model switcher used by Settings, the chat window and the
/// quick-chat panel: persists the change, refreshes every live BrainAgent
/// and posts a notification so open windows cascade too (one source of
/// truth — switching in any surface affects all of them on the next turn).
enum AISettingsCoordinator {
    static let changedNotification = Notification.Name("aiSettingsChanged")

    /// Apply a vendor and/or model change, persist it, and cascade.
    @MainActor
    static func apply(vendor: AIVendor? = nil, model: String? = nil) {
        var settings = AISettings.load()
        if let vendor { settings.switchVendor(to: vendor) }
        if let model { settings.model = model }
        settings.save()
        broadcast(settings)
    }

    /// Select a builtin vendor OR a custom provider profile (ZCode-style
    /// pickers produce this union type).
    @MainActor
    static func apply(option: AIProviderOption) {
        var settings = AISettings.load()
        switch option {
        case .builtin(let vendor): settings.switchVendor(to: vendor)
        case .profile(let id): settings.selectProfile(id: id)
        }
        settings.save()
        broadcast(settings)
    }

    /// Push current settings to live agents without persisting.
    @MainActor
    static func broadcast(_ settings: AISettings) {
        QuickChat.shared.brain.refreshModel(settings: settings)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

// MARK: - Per-vendor model catalog (editable + API-refreshable)

/// Each vendor keeps an editable model list: seeded from the bundled
/// `knownModels`, replaceable from the vendor's models endpoint, and freely
/// edited in Settings (add/delete rows) to correct drift. Pickers and
/// `switchVendor` read through here — never the bundled list directly — so
/// an API refresh or a user edit reaches every surface on the next render.
enum AIModelCatalog {
    static let changedNotification = Notification.Name("aiModelCatalogChanged")
    private static let storageKey = "ai.model-catalogs"

    private static func loadAll() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return dict
    }

    private static func storeAll(_ dict: [String: [String]]) {
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Effective menu for a vendor: the codex backend catalog (API-backed,
    /// own storage), else the user/API catalog when one exists, else the
    /// bundled seed.
    static func models(for vendor: AIVendor) -> [String] {
        if vendor == .codex { return CodexSubscription.modelCatalog }
        if let stored = loadAll()[vendor.rawValue] { return stored }
        return vendor.knownModels
    }

    static func setModels(_ models: [String], for vendor: AIVendor) {
        if vendor == .codex { CodexSubscription.setCatalog(models); return }
        var all = loadAll()
        all[vendor.rawValue] = models
        storeAll(all)
    }

    static func addModel(_ id: String, for vendor: AIVendor) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var models = models(for: vendor)
        guard !models.contains(trimmed) else { return }
        models.append(trimmed)
        setModels(models, for: vendor)
    }

    static func removeModel(_ id: String, for vendor: AIVendor) {
        setModels(models(for: vendor).filter { $0 != id }, for: vendor)
    }

    /// Whether "refresh from API" applies (custom providers have no listing
    /// contract; the user curates those by hand).
    static func supportsAPIRefresh(_ vendor: AIVendor) -> Bool {
        vendor != .custom
    }

    /// Fetch the vendor's live model ids and replace the catalog, correcting
    /// the selected model if the backend dropped it. Returns a user-facing
    /// result line (✓ count / ✗ reason).
    @discardableResult
    static func refreshFromAPI(for vendor: AIVendor, force: Bool = true) async -> String {
        if vendor == .codex {
            let fetched = await CodexSubscription.refreshModels(force: force)
            guard let models = fetched else {
                return "✗ catalog unchanged (offline or token missing?)"
            }
            return "✓ \(models.count) models"
        }
        guard let spec = apiSpec(for: vendor) else { return "✗ no models endpoint for this provider" }
        let settings = AISettings.load()
        guard settings.vendor == vendor else { return "✗ switch to this provider first (needs its key)" }
        guard !spec.url.isEmpty else { return "✗ set a Base URL first" }
        // User-entered base URLs can contain spaces/invalid characters —
        // force-unwrapping crashed the app from the Refresh button.
        guard let requestURL = URL(string: spec.url) else {
            return "✗ invalid base URL: \(settings.baseURL)"
        }

        var request = URLRequest(url: requestURL)
        for (field, value) in spec.headers { request.setValue(value, forHTTPHeaderField: field) }
        request.timeoutInterval = 20
        do {
            let (data, response) = try await CodexSubscription.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "✗ no response" }
            guard (200..<300).contains(http.statusCode) else {
                return "✗ HTTP \(http.statusCode) — check the API key"
            }
            guard let fetched = parseModelIDs(data, vendor: vendor), !fetched.isEmpty else {
                return "✗ unexpected response shape — edit the list by hand"
            }
            let previous = models(for: vendor)
            setModels(fetched, for: vendor)
            if settings.model.isEmpty || !models(for: vendor).contains(settings.model) {
                let corrected = fetched.first { $0 == vendor.defaultModel } ?? fetched[0]
                await MainActor.run { AISettingsCoordinator.apply(model: corrected) }
            } else if fetched != previous {
                await MainActor.run { AISettingsCoordinator.broadcast(AISettings.load()) }
            }
            return "✓ \(fetched.count) models"
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }

    private struct APISpec {
        let url: String
        let headers: [String: String]
    }

    /// Listing endpoint per vendor. Uses the persisted settings so a custom
    /// Base URL (GLM/Ollama mirrors) is respected for the active vendor.
    private static func apiSpec(for vendor: AIVendor) -> APISpec? {
        let settings = AISettings.load()
        let key = settings.apiKey
        let configuredBase = settings.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch vendor {
        case .codex:
            return nil    // handled through CodexSubscription.refreshModels
        case .openai:
            return APISpec(url: "https://api.openai.com/v1/models",
                           headers: ["Authorization": "Bearer \(key)"])
        case .anthropic:
            return APISpec(url: "https://api.anthropic.com/v1/models",
                           headers: ["x-api-key": key, "anthropic-version": "2023-06-01"])
        case .google:
            return APISpec(url: "https://generativelanguage.googleapis.com/v1beta/models",
                           headers: ["x-goog-api-key": key])
        case .deepseek:
            return APISpec(url: "https://api.deepseek.com/models",
                           headers: ["Authorization": "Bearer \(key)"])
        case .groq:
            return APISpec(url: "https://api.groq.com/openai/v1/models",
                           headers: ["Authorization": "Bearer \(key)"])
        case .mistral:
            return APISpec(url: "https://api.mistral.ai/v1/models",
                           headers: ["Authorization": "Bearer \(key)"])
        case .glm:
            let base = configuredBase.isEmpty ? "https://open.bigmodel.cn/api/paas/v4" : configuredBase
            return APISpec(url: "\(base)/models",
                           headers: ["Authorization": "Bearer \(key)"])
        case .ollama:
            let base = configuredBase.isEmpty ? "http://127.0.0.1:11434/v1" : configuredBase
            // Ollama lists models under /api/tags (no /v1 prefix).
            let root = base.hasSuffix("/v1") ? String(base.dropLast(3)) : base
            return APISpec(url: "\(root)/api/tags", headers: [:])
        case .custom:
            return nil
        }
    }

    /// Tolerant decoder for the various /models shapes: OpenAI-style
    /// `{"data":[{"id":…}]}`, Gemini-style `{"models":[{"name":"models/…"}]}`
    /// (prefix stripped), slug/id/model keys, and bare string arrays. Obvious
    /// non-chat entries (embeddings, tts, image, moderation) are filtered.
    static func parseModelIDs(_ data: Data, vendor: AIVendor) -> [String]? {
        let noise = ["embedding", "embed", "whisper", "tts", "dall-e", "moderation", "rerank", "guard"]
        func clean(_ id: String) -> String? {
            var value = id
            if value.hasPrefix("models/") { value = String(value.dropFirst("models/".count)) }
            guard !value.isEmpty else { return nil }
            let lowered = value.lowercased()
            return noise.contains { lowered.contains($0) } ? nil : value
        }
        func ids(_ items: [[String: Any]]) -> [String] {
            items.compactMap { item in
                let raw = item["id"] ?? item["slug"] ?? item["name"] ?? item["model"]
                return (raw as? String).flatMap(clean)
            }
        }
        func collect(_ json: Any) -> [String]? {
            if let strings = json as? [String] {
                let models = strings.compactMap(clean)
                return models.isEmpty ? nil : models
            }
            if let items = json as? [[String: Any]] {
                let models = ids(items)
                return models.isEmpty ? nil : models
            }
            return nil
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["data", "models", "items"] {
                if let found = collect(json[key] as Any) { return found }
            }
        }
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return collect(json)
        }
        return nil
    }
}

// MARK: - Model resolution (swift-ai-sdk providers)

enum AIModelFactory {

    /// Builds a LanguageModel from settings using the matching provider.
    static func makeModel(_ settings: AISettings) throws -> any LanguageModelConvertible {
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        let key = settings.apiKey.isEmpty ? nil : settings.apiKey

        // ZCode-style provider profiles: transport follows the profile's
        // "API 格式" — Chat Completions, Anthropic Messages or Responses,
        // all against the custom base URL.
        if let profile = settings.activeProfile {
            guard let base = URL(string: profile.baseURL.trimmingCharacters(in: .whitespaces)) else {
                throw NSError(domain: "ai", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "invalid base URL: \(profile.baseURL)"])
            }
            switch profile.effectiveFormat {
            case .chatCompletions:
                let provider = createOpenAICompatible(
                    settings: OpenAICompatibleProviderSettings(
                        baseURL: base.absoluteString,
                        name: profile.id,
                        apiKey: key
                    )
                )
                return provider(model)
            case .anthropic:
                let provider = createAnthropic(settings: AnthropicProviderSettings(
                    baseURL: base.absoluteString, apiKey: key))
                return try provider.chatModel(modelId: model)
            case .responses:
                let provider = try createOpenResponses(options: OpenResponsesProviderSettings(
                    url: base.absoluteString, name: profile.id, apiKey: key))
                return provider.languageModel(modelId: model)
            }
        }

        switch settings.vendor {
        case .openai:
            let provider = try createOpenAI(settings: OpenAIProviderSettings(apiKey: key))
            return try provider.chatModel(modelId: model)
        case .anthropic:
            let provider = createAnthropic(settings: AnthropicProviderSettings(apiKey: key))
            return try provider.chatModel(modelId: model)
        case .google:
            let provider = createGoogle(settings: GoogleProviderSettings(apiKey: key))
            return try provider.languageModel(modelId: model)
        case .deepseek:
            let provider = createDeepSeek(settings: DeepSeekProviderSettings(apiKey: key))
            return try provider.chatModel(modelId: model)
        case .groq:
            let provider = createGroq(settings: GroqProviderSettings(apiKey: key))
            return provider.languageModel(modelId: model)
        case .mistral:
            let provider = createMistral(settings: MistralProviderSettings(apiKey: key))
            return provider.languageModel(modelId: model)
        case .codex:
            throw BrainError("codex vendor uses the subscription transport (see BrainAgent)")
        case .glm, .ollama, .custom:
            guard let base = URL(string: settings.baseURL.trimmingCharacters(in: .whitespaces)) else {
                throw NSError(domain: "ai", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "invalid base URL: \(settings.baseURL)"])
            }
            let provider = createOpenAICompatible(
                settings: OpenAICompatibleProviderSettings(
                    baseURL: base.absoluteString,
                    name: settings.vendor.rawValue,
                    apiKey: key
                )
            )
            return provider(model)
        }
    }
}

// MARK: - JSON bridges (ToolRegistry ⇄ swift-ai-sdk)

enum JSONBridge {

    /// Any JSON-serializable object (from JSONSerialization) → JSONValue.
    static func toJSONValue(_ any: Any) -> JSONValue {
        switch any {
        case let dict as [String: Any]:
            return .object(dict.mapValues(toJSONValue))
        case let array as [Any]:
            return .array(array.map(toJSONValue))
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if number.isBoolean { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let bool as Bool:
            return .bool(bool)
        case is NSNull:
            return .null
        default:
            return .string(String(describing: any))
        }
    }

    /// JSONValue → [String: Any] for ToolRegistry argument passing.
    static func toArgs(_ json: JSONValue) -> [String: Any] {
        if case .object(let dict) = json {
            return dict.mapValues(toAny)
        }
        return [:]
    }

    static func toAny(_ json: JSONValue) -> Any {
        switch json {
        case .object(let dict): return dict.mapValues(toAny)
        case .array(let array): return array.map(toAny)
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }
}

extension NSNumber {
    var isBoolean: Bool {
        CFGetTypeID(self) == CFBooleanGetTypeID()
    }
}

// MARK: - Tool bridge

/// Converts ToolRegistry tools into swift-ai-sdk ToolSet entries. The SDK's
/// agent loop calls `execute` automatically and feeds results back to the
/// model until it stops calling tools or hits the step limit.
enum AIToolBridge {

    static func toolSet() -> ToolSet {
        var set: ToolSet = [:]
        for registryTool in ToolRegistry.tools {
            let name = registryTool.name
            let schema = JSONBridge.toJSONValue(registryTool.jsonSchema)
            let description = registryTool.description
            set[name] = tool(
                description: ToolDescription(stringLiteral: description),
                inputSchema: FlexibleSchema(jsonSchema(schema)),
                execute: { input, _ in
                    let args = JSONBridge.toArgs(input)
                    do {
                        let text = try await ToolRegistry.execute(
                            name: name, args: args, approval: .ui
                        )
                        return .value(.string(text))
                    } catch {
                        // Thrown tool errors are surfaced to the model as
                        // tool errors, letting it recover conversationally.
                        throw error
                    }
                }
            )
        }
        return set
    }
}

// MARK: - Connection test (Settings)

enum AIConnectionTest {
    static func test(_ settings: AISettings) async -> String {
        do {
            let model = try AIModelFactory.makeModel(settings)
            let result = try await generateText(
                model: model,
                prompt: "Reply with exactly: ok",
                settings: CallSettings(maxOutputTokens: 16)
            )
            return "Connected ✓ \(result.text.prefix(40))"
        } catch {
            return "Failed: \(error.localizedDescription.prefix(160))"
        }
    }
}
