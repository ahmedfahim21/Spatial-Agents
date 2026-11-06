import SwiftUI

// The design language: light, native iOS. Ink (black) is the accent; colour belongs to the
// agents. Motion is critically damped springs, presses answer on touch-down, nothing
// appears from nothing.

// MARK: - The cast: 8 colours × 5 shapes

enum BotColor: String, CaseIterable, Identifiable {
    case cyan, orange, violet, green, pink, yellow, blue, red

    var id: String { rawValue }

    var hex: String {
        switch self {
        case .cyan: "#36D1DC"
        case .orange: "#FF8A5B"
        case .violet: "#A78BFA"
        case .green: "#4ADE80"
        case .pink: "#F472B6"
        case .yellow: "#FACC15"
        case .blue: "#60A5FA"
        case .red: "#F87171"
        }
    }

    var color: Color { Color(hex: hex)! }

    /// The palette colour for a stored hex; unknown colours fall back to cyan.
    static func from(hex: String?) -> BotColor {
        allCases.first { $0.hex.caseInsensitiveCompare(hex ?? "") == .orderedSame } ?? .cyan
    }
}

enum BotShape: String, CaseIterable, Identifiable {
    case circle, hexagon, squircle, capsule, drop

    var id: String { rawValue }

    var label: String { rawValue.capitalized }

    /// Agents saved before shapes existed still get a stable one.
    static func stable(for id: UUID) -> BotShape {
        let byte = withUnsafeBytes(of: id.uuid) { $0[15] }
        return allCases[Int(byte) % allCases.count]
    }
}

extension Agent {
    var botColor: BotColor { BotColor.from(hex: color) }
    var botShape: BotShape { BotShape(rawValue: shape ?? "") ?? .stable(for: id) }
    /// Desynchronises blinking between agents.
    var seed: Double { Double(withUnsafeBytes(of: id.uuid) { $0[3] }) / 255 }
}

// MARK: - Motion

enum Motion {
    /// Default for UI state changes: no overshoot.
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 1)
    /// Things moving across the screen.
    static let smooth = Animation.spring(response: 0.42, dampingFraction: 1)
    /// Only for physical moments (a hop, a drop landing).
    static let lively = Animation.spring(response: 0.32, dampingFraction: 0.68)
}

// MARK: - Buttons

/// Black capsule, full width: the one main action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color(.systemBackground))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.primary.opacity(isEnabled ? 1 : 0.25), in: Capsule())
            .pressable(configuration.isPressed)
    }
}

/// Grey capsule: secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, fullWidth ? 0 : 16)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 50 : 36)
            .background(Color(.systemGray5), in: Capsule())
            .pressable(configuration.isPressed)
    }
}

/// Round grey icon button (close, back, recenter).
struct CircleButtonStyle: ButtonStyle {
    var size: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Color(.systemGray5), in: Circle())
            .pressable(configuration.isPressed)
    }
}

/// Any tappable surface (rows, cards, tiles): a gentle press-down.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .pressable(configuration.isPressed, scale: 0.98)
    }
}

extension View {
    /// Press feedback that answers on touch-down: a slight scale, fast ease-out.
    func pressable(_ pressed: Bool, scale: CGFloat = 0.97) -> some View {
        scaleEffect(pressed ? scale : 1)
            .opacity(pressed ? 0.85 : 1)
            .animation(.easeOut(duration: pressed ? 0.1 : 0.16), value: pressed)
    }

    /// A white rounded card on the grouped background.
    func card(padding: CGFloat = 0) -> some View {
        self.padding(padding)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Text

/// "NEARBY", "COLOUR AND SHAPE"…: the small caps header above a card.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Screen title in the design's large style, for screens with custom headers.
struct ScreenTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 34, weight: .bold))
            .tracking(-0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row divider that starts after the leading artwork, like grouped lists.
struct RowDivider: View {
    var leading: CGFloat = 16
    var body: some View {
        Rectangle().fill(Color(.separator)).frame(height: 0.5).padding(.leading, leading)
    }
}

// MARK: - Words

enum Words {
    /// "42 m", "1.2 km".
    static func distance(_ m: Double) -> String { GeoMath.describe(distance: m) }

    /// "north-east" for a bearing in degrees.
    static func compass(_ bearing: Double) -> String {
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return names[Int((normalize360(bearing) + 22.5) / 45) % 8]
    }

    static func compassShort(_ bearing: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((normalize360(bearing) + 22.5) / 45) % 8]
    }

    /// Where something is relative to where you face: "ahead, slightly right".
    static func direction(_ relative: Double) -> String {
        let a = normalizeAngle(relative)
        switch abs(a) {
        case ..<12: return "straight ahead"
        case ..<40: return a > 0 ? "ahead, slightly right" : "ahead, slightly left"
        case ..<70: return a > 0 ? "ahead to your right" : "ahead to your left"
        case ..<115: return a > 0 ? "to your right" : "to your left"
        case ..<160: return a > 0 ? "behind you, right" : "behind you, left"
        default: return "behind you"
        }
    }

    /// "just ahead of you", "on your left": for spoken-voice hints.
    static func voiceDirection(_ relative: Double) -> String {
        let a = normalizeAngle(relative)
        switch abs(a) {
        case ..<25: return "just ahead of you"
        case ..<70: return a > 0 ? "ahead on your right" : "ahead on your left"
        case ..<120: return a > 0 ? "on your right" : "on your left"
        default: return "behind you"
        }
    }
}
