import Foundation

// MARK: - ZCode-style custom provider profiles
//
// ZCode configures models as `providerId/modelId` pairs backed by a plain,
// hand-editable config file. Moppet gets the same shape: any number of
// user-defined OpenAI-compatible providers (`~/.moppet/ai-providers.json`),
// each with its own base URL, Keychain API key and model list, listed in the
// provider pickers next to the built-in vendors.

/// Wire protocol a custom provider speaks (ZCode's "API 格式" selector).
/// All three SDK transports accept a custom base URL, so a profile can point
/// at a gateway speaking any of them.
enum AIProviderFormat: String, Codable, CaseIterable, Identifiable {
    /// The three options of ZCode's "API 格式" selector, verbatim.
    case chatCompletions = "chat-completions"   // Chat Completions (/chat/completions)
    case anthropic = "anthropic"                // Anthropic Messages (/v1/messages)
    case responses = "responses"                // Responses (/responses)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatCompletions: "Chat Completions (/chat/completions)"
        case .anthropic: "Anthropic Messages (/v1/messages)"
        case .responses: "Responses (/responses)"
        }
    }

    var shortName: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .anthropic: "Anthropic Messages"
        case .responses: "Responses"
        }
    }
}

struct AIProviderProfile: Codable, Identifiable, Equatable, Hashable {
    /// URL-safe slug used in keychain keys and selection persistence.
    var id: String
    var name: String
    var baseURL: String
    var models: [String]
    /// Wire protocol; nil in pre-format config files means OpenAI-compatible.
    var format: AIProviderFormat?

    var defaultModel: String { models.first ?? "" }
    var effectiveFormat: AIProviderFormat { format ?? .chatCompletions }

    init(id: String, name: String, baseURL: String, models: [String],
         format: AIProviderFormat = .chatCompletions) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.models = models
        self.format = format
    }

    enum CodingKeys: String, CodingKey { case id, name, baseURL, models, format }
}

/// One selectable entry in provider pickers: a built-in vendor or a profile.
enum AIProviderOption: Hashable, Identifiable {
    case builtin(AIVendor)
    case profile(String)

    var id: String {
        switch self {
        case .builtin(let vendor): return "builtin:\(vendor.rawValue)"
        case .profile(let id): return "profile:\(id)"
        }
    }

    var label: String {
        switch self {
        case .builtin(let vendor): return vendor.displayName
        case .profile(let id):
            return AIProviderRegistry.profile(id: id)?.name ?? id
        }
    }

    /// The ZCode-style `provider/model` display string.
    var qualifiedName: String {
        switch self {
        case .builtin(let vendor): return "\(vendor.rawValue)/…"
        case .profile(let id): return "\(id)/…"
        }
    }
}

enum AIProviderRegistry {
    static let changedNotification = Notification.Name("aiProviderProfilesChanged")

    /// Plain-file config (inspectable and hand-editable, like ZCode's).
    static var fileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("ai-providers.json")
    }

    static func load() -> [AIProviderProfile] {
        guard let data = try? Data(contentsOf: fileURL),
              let profiles = try? JSONDecoder().decode([AIProviderProfile].self, from: data) else {
            return []
        }
        return profiles
    }

    private static func store(_ profiles: [AIProviderProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        try? data.write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func profile(id: String) -> AIProviderProfile? {
        load().first { $0.id == id }
    }

    /// Display names must be unique — they are what the AI Provider pickers
    /// show, and duplicates make the choice ambiguous. Case-insensitive,
    /// whitespace-trimmed.
    static func nameExists(_ name: String, excludingID: String? = nil) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespaces).lowercased()
        return load().contains { profile in
            profile.id != excludingID
                && profile.name.trimmingCharacters(in: .whitespaces).lowercased() == candidate
        }
    }

    /// Rename keeping the stable id (keychain slot + selection survive).
    @discardableResult
    static func rename(id: String, to newName: String) -> [AIProviderProfile] {
        guard var profile = profile(id: id) else { return load() }
        profile.name = newName.trimmingCharacters(in: .whitespaces)
        return upsert(profile)
    }

    static func slugify(_ name: String) -> String {
        let base = name.lowercased()
            .map { character -> Character in
                ("a"..."z").contains(String(character)) || ("0"..."9").contains(String(character))
                    || character == "-" ? character : "-"
            }
            .reduce(into: "") { result, character in
                if !(result.hasSuffix("-") && character == "-") { result.append(character) }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return base.isEmpty ? "provider-\(UUID().uuidString.prefix(6).lowercased())" : base
    }

    /// All mutations funnel through one lock — concurrent upserts (settings
    /// editor vs model-catalog refresh) used to lose each other's writes.
    private static let registryLock = NSLock()

    /// `isNew` = this call ADDS a provider (suffix on slug collision) rather
    /// than updating/renaming an existing one (whose id must stay stable).
    /// The old guard was always false, so adding "Test" then "Test!" replaced
    /// the first provider (config + key) instead of creating a second one.
    @discardableResult
    static func upsert(_ profile: AIProviderProfile, isNew: Bool = false) -> [AIProviderProfile] {
        registryLock.lock()
        defer { registryLock.unlock() }
        var all = load()
        var updated = profile
        if isNew, all.contains(where: { $0.id == updated.id }) {
            var suffix = 2
            while all.contains(where: { $0.id == "\(updated.id)-\(suffix)" }) {
                suffix += 1
            }
            updated.id = "\(updated.id)-\(suffix)"
        }
        if let index = all.firstIndex(where: { $0.id == updated.id }) {
            all[index] = updated
        } else {
            all.append(updated)
        }
        store(all)
        return all
    }

    /// Deletes the profile and its keychain key. Returns the ids deleted.
    @discardableResult
    static func delete(id: String) -> [AIProviderProfile] {
        let all = load().filter { $0.id != id }
        store(all)
        APIKeyStore.delete(slot: AIProviderProfileKey(id))
        // A deleted active profile falls back to the last builtin vendor.
        var settings = AISettings.load()
        if settings.activeProfileID == id {
            // The old fixup left vendor == .custom with no profile and no key
            // (half-dead state) — fall back to a real builtin like the
            // settings-page delete path does.
            settings.switchVendor(to: settings.vendor == .custom ? .glm : settings.vendor)
            settings.save()
            Task { @MainActor in AISettingsCoordinator.broadcast(settings) }
        }
        return all
    }
}

/// Keychain slot for one profile's API key.
func AIProviderProfileKey(_ id: String) -> String {
    "api-key.profile:\(id)"
}

// MARK: - Model catalog for profiles

extension AIModelCatalog {
    /// A profile's model menu is the profile itself (its models field is the
    /// curated list; refresh rewrites it from the endpoint).
    static func models(forProfile id: String) -> [String] {
        AIProviderRegistry.profile(id: id)?.models ?? []
    }

    static func setModels(_ models: [String], forProfile id: String) {
        guard var profile = AIProviderRegistry.profile(id: id) else { return }
        profile.models = models
        AIProviderRegistry.upsert(profile)
    }

    /// Listing URL + auth headers per wire format (OpenAI `{base}/models`
    /// Bearer; Anthropic `{base}/v1/models` x-api-key; Google
    /// `{base}/v1beta/models` x-goog-api-key — the built-in vendors'
    /// endpoints applied to the profile's base URL).
    static func listingSpec(_ profile: AIProviderProfile) -> (url: String, headers: [String: String]) {
        let base = profile.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let key = APIKeyStore.read(slot: AIProviderProfileKey(profile.id)) ?? ""
        switch profile.effectiveFormat {
        case .chatCompletions, .responses:
            // Both OpenAI formats list models at {base}/models with Bearer.
            return ("\(base)/models", key.isEmpty ? [:] : ["Authorization": "Bearer \(key)"])
        case .anthropic:
            let stem = base.hasSuffix("/v1") ? base : "\(base)/v1"
            return ("\(stem)/models", key.isEmpty ? [:] :
                ["x-api-key": key, "anthropic-version": "2023-06-01"])
        }
    }

    /// Refreshes a profile's model list from its listing endpoint.
    @discardableResult
    static func refreshProfile(_ profile: AIProviderProfile) async -> String {
        guard !profile.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty else {
            return "✗ set a Base URL first"
        }
        let spec = listingSpec(profile)
        guard let url = URL(string: spec.url) else {
            return "✗ invalid base URL: \(profile.baseURL)"
        }
        var request = URLRequest(url: url)
        for (field, value) in spec.headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.timeoutInterval = 20
        do {
            let (data, response) = try await CodexSubscription.session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "✗ no response" }
            guard (200..<300).contains(http.statusCode) else {
                return "✗ HTTP \(http.statusCode) — check the base URL / API key"
            }
            guard let fetched = parseModelIDs(data, vendor: .custom), !fetched.isEmpty else {
                return "✗ unexpected response shape — edit the model list by hand"
            }
            var updated = profile
            updated.models = fetched
            AIProviderRegistry.upsert(updated)
            return "✓ \(fetched.count) models"
        } catch {
            return "✗ \(error.localizedDescription)"
        }
    }
}

// MARK: - Settings integration

extension AISettings {
    /// The active custom provider profile, if any (overrides the builtin
    /// vendor for transport; `vendor` is kept in sync as `.custom`).
    var activeProfile: AIProviderProfile? {
        guard let activeProfileID else { return nil }
        return AIProviderRegistry.profile(id: activeProfileID)
    }

    var providerOption: AIProviderOption {
        if let activeProfileID {
            return .profile(activeProfileID)
        }
        return .builtin(vendor)
    }

    /// Effective provider label for headers/footers.
    var transportName: String {
        if let activeProfile { return activeProfile.name }
        return vendor.displayName
    }

    /// Selects a profile: routes transport + baseURL + model + key through it.
    mutating func selectProfile(id: String) {
        guard let profile = AIProviderRegistry.profile(id: id) else { return }
        activeProfileID = id
        vendor = .custom             // chat-completions transport semantics
        baseURL = profile.baseURL
        if !profile.models.contains(model) {
            model = profile.defaultModel
        }
        apiKey = APIKeyStore.read(slot: AIProviderProfileKey(id)) ?? ""
    }

    /// Persists a profile's API key to its own keychain slot.
    func saveProfileKey() {
        guard let activeProfileID else { return }
        let key = AIProviderProfileKey(activeProfileID)
        if apiKey.isEmpty {
            APIKeyStore.delete(slot: key)
        } else {
            APIKeyStore.write(apiKey, slot: key)
        }
    }
}


