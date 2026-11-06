import Foundation

/// Two windows for your personal agents: one on your left, one on your right, fixed to your
/// head. A quick turn toward a side, from wherever you're facing, picks its agent.
enum Zone: String, CaseIterable, Codable, Identifiable {
    case left, right

    var id: String { rawValue }

    /// Where its voice comes from, degrees (+ = right), fixed to your head: the left agent is
    /// always in your left ear.
    var azimuth: Double { self == .left ? -45 : 45 }

    /// Degrees above eye level.
    var elevation: Double { 0 }

    var name: String { self == .left ? "Left" : "Right" }

    var windowName: String { self == .left ? "Left window" : "Right window" }

    /// For the agent to say where it is.
    var spoken: String { self == .left ? "here on your left" : "here on your right" }

    /// New agents take the left window first.
    static let fillOrder: [Zone] = [.left, .right]
}
