import Foundation

/// Six places around you for your personal agents: three at eye level, three above.
/// All in front of you, so every agent is a comfortable head turn away (the back is
/// hard to hear precisely and awkward to face).
enum Zone: String, CaseIterable, Codable, Identifiable {
    case upperLeft, upperCenter, upperRight, left, center, right

    var id: String { rawValue }
    var isUpper: Bool { self == .upperLeft || self == .upperCenter || self == .upperRight }

    /// Degrees, + = right.
    var azimuth: Double {
        switch self {
        case .upperLeft, .left: return -55
        case .upperCenter, .center: return 0
        case .upperRight, .right: return 55
        }
    }

    /// Degrees above eye level.
    var elevation: Double { isUpper ? 32 : 0 }

    var name: String {
        switch self {
        case .upperLeft: return "Up left"
        case .upperCenter: return "Up front"
        case .upperRight: return "Up right"
        case .left: return "Left"
        case .center: return "Front"
        case .right: return "Right"
        }
    }

    /// For the agent to say where it is.
    var spoken: String {
        switch self {
        case .upperLeft: return "up here, on your left"
        case .upperCenter: return "up here, straight ahead"
        case .upperRight: return "up here, on your right"
        case .left: return "here on your left"
        case .center: return "right in front of you"
        case .right: return "here on your right"
        }
    }

    /// New agents fill eye level first, centre outwards.
    static let fillOrder: [Zone] = [.center, .left, .right, .upperCenter, .upperLeft, .upperRight]
}
