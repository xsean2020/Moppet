import Foundation

/// User-customizable pet identity: name and persona (system prompt soul).
/// Stored in UserDefaults / ~/.moppet/brain/persona.md so the Brain's
/// system prompt can absorb both on every turn.
enum PetIdentity {

    static let nameKey = "pet.name"
    static var defaultName = "Moley"

    static var name: String {
        let stored = UserDefaults.standard.string(forKey: nameKey) ?? ""
        return stored.trimmingCharacters(in: .whitespaces).isEmpty ? defaultName : stored
    }

    static func setName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmed, forKey: nameKey)
    }

    // MARK: - Persona (soul)

    static var personaFile: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet/brain")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("persona.md")
    }

    static var persona: String? {
        guard let text = try? String(contentsOf: personaFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func savePersona(_ text: String) {
        try? text.write(to: personaFile, atomically: true, encoding: .utf8)
    }

    /// Applicable persona heading (shown in Settings preview).
    static var personaSummary: String {
        persona.map { String($0.prefix(120)) } ?? "Default personality (cute, diligent mole agent)"
    }
}
