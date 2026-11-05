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
    var status: AgentStatus = .idle
    var lastReply: String = ""
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let speaker: String
    let text: String
    let fromUser: Bool
}

/// Wraps any angle into -180...180.
func normalizeAngle(_ a: Double) -> Double {
    var x = a.truncatingRemainder(dividingBy: 360)
    if x > 180 { x -= 360 }
    if x < -180 { x += 360 }
    return x
}

/// Turns a long Claude reply into something short enough to listen to.
enum Summarizer {
    static func spoken(_ text: String, isError: Bool) -> String {
        var t = text
        // Drop fenced code blocks entirely: nobody wants code read aloud.
        while let start = t.range(of: "```") {
            if let end = t.range(of: "```", range: start.upperBound..<t.endIndex) {
                t.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                t.removeSubrange(start.lowerBound..<t.endIndex)
            }
        }
        t = t.replacingOccurrences(of: "[#*`_>|]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return isError ? "Something went wrong." : "Done." }

        var out = ""
        var count = 0
        t.enumerateSubstrings(in: t.startIndex..<t.endIndex, options: .bySentences) { sub, _, _, stop in
            guard let s = sub else { return }
            if !out.isEmpty && out.count + s.count > 280 { stop = true; return }
            out += s
            count += 1
            if count >= 2 { stop = true }
        }
        if out.isEmpty { out = String(t.prefix(280)) }
        return isError ? "Problem. " + out : out
    }
}
