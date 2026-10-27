import Foundation
import Observation

/// Chat window session management — one Brain session per chat, backed by
/// the rollout store: list / new / switch (resume) / delete.
@Observable
final class ChatSessionStore {

    struct SessionInfo: Identifiable, Equatable {
        let id: String
        var title: String
        var date: Date
        var itemCount: Int
        var isBrain: Bool = true
    }

    private(set) var sessions: [SessionInfo] = []
    /// True count of on-disk sessions with content — the list above is the
    /// capped recent window, NOT the total (with 60+ rollouts the footer
    /// read as "delete doesn't work" because it never moved off the cap).
    private(set) var totalSessions = 0
    /// The live agent for the active conversation. Swapped on switch/new.
    private(set) var brain: BrainAgent
    private(set) var currentSessionID: String?

    init() {
        brain = ChatSessionStore.makeAgent()
        refresh()
    }

    private static func makeAgent(resuming sessionID: String? = nil) -> BrainAgent {
        let agent = BrainAgent()
        if let sessionID {
            agent.resume(sessionID: sessionID)
        }
        // Pet announcements follow the AGENT, not the view: wiring only in
        // ChatView.onAppear used to lose error/approval announcements for
        // every session created or switched to afterwards.
        agent.onEvent = { event in
            switch event {
            case .error(let message):
                // Sad pose, not idle — a failure used to look like nothing
                // happened (the sad sticker was dead code until now).
                PetBus.shared.say(L("Oops, error:") + " \(message.prefix(60))", state: .sad)
            case .approvalRequested(let name, _):
                PetBus.shared.say(L("Needs your approval:") + " \(name)", state: .talking)
            default:
                break
            }
        }
        return agent
    }

    // MARK: - Session list

    func refresh() {
        // Rollout enumeration reads every session file (some carry base64
        // images) — that walk used to run synchronously on the main thread
        // on every window open / send / delete.
        Task.detached {
            let (rollouts, total) = BrainRollout.listSessions(limit: 50)
            let infos = rollouts.map { entry in
                SessionInfo(
                    id: entry.id,
                    title: BrainRollout.titleForSession(sessionID: entry.id)
                        ?? "Session \(entry.date.formatted(date: .abbreviated, time: .shortened))",
                    date: entry.date,
                    itemCount: entry.itemCount
                )
            }
            await MainActor.run {
                self.totalSessions = total
                self.sessions = infos
            }
        }
    }

    // MARK: - Actions

    /// Start a brand-new conversation. The rollout file is created lazily by
    /// the first submit (BrainAgent.submit begins the session) — an abandoned
    /// "+" click leaves zero junk on disk.
    func newSession() {
        if brain.isRunning { brain.cancel() }
        brain = ChatSessionStore.makeAgent()
        currentSessionID = brain.sessionID
        refresh()
    }

    /// Switch to (resume) an existing rollout session.
    func resume(_ info: SessionInfo) {
        if brain.isRunning { brain.cancel() }
        brain = ChatSessionStore.makeAgent(resuming: info.id)
        currentSessionID = info.id
    }

    /// Delete a rollout from disk; if it is the active session start a new one.
    func delete(_ info: SessionInfo) {
        deleteAll([info.id])
    }

    /// Batch-delete rollouts from disk; if the active session is among them
    /// start a new one (single-delete shares this path).
    func deleteAll(_ ids: [String]) {
        for id in ids {
            try? FileManager.default.removeItem(at: BrainRollout.fileURL(for: id))
        }
        if let current = currentSessionID, ids.contains(current) {
            newSession()
        }
        refresh()
    }

    /// Called after the first user message of a fresh session so the sidebar
    /// title updates and the session appears in the list.
    func syncCurrentSession() {
        if currentSessionID != brain.sessionID {
            currentSessionID = brain.sessionID
        }
        refresh()
    }
}
