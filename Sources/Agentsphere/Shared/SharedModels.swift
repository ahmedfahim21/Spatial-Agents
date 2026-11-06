import Combine
import Foundation

/// One line in an agent's chat.
struct ChatMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case agent
        case tool(name: String)
        case permission(PermissionState)
        case note
        case error
    }
    enum PermissionState: Equatable { case asking, approved, denied }

    let id: UUID
    var kind: Kind
    var text: String
    let date: Date

    init(id: UUID = UUID(), _ kind: Kind, _ text: String, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.date = date
    }
}

/// Head orientation, ~25 updates a second. Kept out of AppState so only the views that
/// draw the head redraw; otherwise every window re-renders on every head movement.
final class HeadMotion: ObservableObject {
    @Published var yaw: Double = 0
    @Published var pitch: Double = 0
    /// 0...1 while you hold your gaze on an agent (iPhone). Lives here so only the views
    /// that draw it redraw 10×/s, not every screen.
    @Published var stare: Double = 0
}

/// An instruction heard hands-free, sent after a short window unless you shake.
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
