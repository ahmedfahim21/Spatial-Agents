import Foundation

enum AgentStatus: String {
    case idle = "Idle"
    case working = "Working…"
    case asking = "Needs approval"
    case waiting = "Has a reply"
    case error = "Error"
}

/// One Claude Code session placed somewhere in the room around you.
struct AgentSession: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var directory: URL
    /// Degrees around your head: 0 = front, +90 = right, -90 = left, 180 = behind.
    var azimuth: Double
    /// Claude Code's own session id, so every turn continues the same conversation.
    var claudeSessionId: String? = nil
    /// The resumed session is open elsewhere (e.g. a terminal): branch it on the next turn
    /// with --fork-session instead of writing into the same transcript.
    var forkNext = false
    /// Claude's title for the attached session, if any.
    var title = ""
    var status: AgentStatus = .idle
    var lastReply: String = ""
    /// The conversation shown in the chat panel.
    var messages: [ChatMessage] = []
}

struct PendingSend: Identifiable {
    let id = UUID()
    let text: String
    let target: UUID
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let speaker: String
    let text: String
    let fromUser: Bool
}

/// Wraps any angle into -180...180.
