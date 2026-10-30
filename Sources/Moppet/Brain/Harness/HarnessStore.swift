import Foundation

/// Where the harness lives on disk, and the degradation contract that keeps the
/// pet from ever running with an empty system prompt (design doc §5.1).
///
/// Chain, in order — the first non-empty answer wins:
///   1. `~/.moppet/brain/harness/` (per-file: a deleted file falls back to its seed)
///   2. the compiled-in seed
///   3. `BrainInstructions.legacySystemPrompt` — unreachable in practice; kept as
///      the last line of defence so a future seed bug cannot silence the pet.
enum HarnessStore {

    /// Test seam: point the store at a temp directory so smoke runs never touch
    /// the user's real `~/.moppet/brain`.
    static var rootOverride: URL?

    static var directory: URL {
        if let rootOverride { return rootOverride }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".moppet/brain/harness", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Write the seed on first run. Returns true when it actually wrote.
    @discardableResult
    static func ensureSeeded() -> Bool {
        let dir = directory
        guard PetHarness.read(from: dir).isEmpty else { return false }
        do {
            try PetHarness.write(PetHarness.seed, to: dir)
            return true
        } catch {
            return false
        }
    }

    /// The tree to compose from: on-disk values, per-file seed fallback, and the
    /// whole seed when the directory is missing or empty.
    static func load() -> PetHarness.Tree {
        let onDisk = PetHarness.read(from: directory)
        guard !onDisk.isEmpty else { return PetHarness.seed }
        return PetHarness.effectiveTree(onDisk)
    }

    /// The system prompt for this turn.
    static func composeSystemPrompt(
        cwd: String,
        sandboxMode: BrainSandboxMode,
        approvalPolicy: BrainApprovalPolicy,
        networkAccess: Bool
    ) -> String {
        let composed = PetHarness.compose(
            tree: load(), cwd: cwd, sandboxMode: sandboxMode,
            approvalPolicy: approvalPolicy, networkAccess: networkAccess)
        if composed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return BrainInstructions.legacySystemPrompt(
                cwd: cwd, sandboxMode: sandboxMode,
                approvalPolicy: approvalPolicy, networkAccess: networkAccess)
        }
        return composed
    }

    // MARK: - Mutation (P1 writes memory / skills through here)

    /// Write one file on the surface, leaving every other file untouched.
    @discardableResult
    static func writeFile(_ rel: String, _ body: String) -> Bool {
        guard HarnessSurface.isAllowed(rel), let path = try? HarnessSurface.normalize(rel) else {
            return false
        }
        let target = directory.appendingPathComponent(path)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: target, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    static func deleteFile(_ rel: String) -> Bool {
        guard let path = try? HarnessSurface.normalize(rel) else { return false }
        do {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(path))
            return true
        } catch {
            return false
        }
    }
}
