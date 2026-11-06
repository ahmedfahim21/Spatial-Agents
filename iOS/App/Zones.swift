import Foundation

/// Two windows around you for your personal agents: one on your left, one on your right,
/// at eye level. Front stays clear for whatever you're actually looking at, and each agent
/// is one clear head turn away.
enum Zone: String, CaseIterable, Codable, Identifiable {
    case left, right

    var id: String { rawValue }

    /// Degrees, + = right.
    var azimuth: Double { self == .left ? -55 : 55 }

    /// Degrees above eye level.
    var elevation: Double { 0 }

    var name: String { self == .left ? "Left" : "Right" }

    var windowName: String { self == .left ? "Left window" : "Right window" }

    /// For the agent to say where it is.
    var spoken: String { self == .left ? "here on your left" : "here on your right" }

    /// New agents take the left window first.
    static let fillOrder: [Zone] = [.left, .right]
}
