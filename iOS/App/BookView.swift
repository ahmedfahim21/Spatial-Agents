import SwiftUI

/// Your two agents as an open book you stand in front of: the left page is your left agent,
/// the right page your right. Glance a little toward a side and that page swings open toward
/// you and lights up; nod and it's listening.
struct BookView: View {
    @Environment(MobileState.self) private var state
    private let pageWidth: CGFloat = 150
    private let pageHeight: CGFloat = 270
    /// How far each page folds toward you at rest, degrees.
    private let fold: Double = 35

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                page(.left)
                page(.right)
            }
            .frame(height: pageHeight)
            .padding(.top, 28)
            you
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func page(_ zone: Zone) -> some View {
        let agent = state.agent(in: zone)
        var lit = agent != nil && (state.focusedId == agent?.id || state.activeId == agent?.id)
        #if DEBUG
        if UserDefaults.standard.string(forKey: "bookLit") == zone.rawValue { lit = true }
        #endif
        let left = zone == .left
        // Turning toward a page starts to open it; a settled glance opens it most of the way.
        let lean = min(1, max(0, (left ? -state.headYaw : state.headYaw) / max(state.glanceSize, 1)))
        let angle = lit ? 8 : fold - (fold - 20) * lean
        let shape = UnevenRoundedRectangle(topLeadingRadius: left ? 20 : 0, bottomLeadingRadius: left ? 20 : 0,
                                           bottomTrailingRadius: left ? 0 : 20, topTrailingRadius: left ? 0 : 20,
                                           style: .continuous)
        return ZStack(alignment: left ? .topLeading : .topTrailing) {
            shape.fill(Color(.secondarySystemGroupedBackground))
            shape.strokeBorder(lit ? Color.accentColor : Color(.systemGray4), lineWidth: lit ? 2 : 1)
            Text(lit && state.activeId != agent?.id ? "\(zone.name) · facing" : zone.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(lit ? Color.accentColor : .secondary)
                .padding(.horizontal, 16).padding(.top, 14)
            content(agent, zone: zone)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: pageWidth, height: pageHeight)
        // Outer edges toward you: you stand inside the book, between the two walls.
        .rotation3DEffect(.degrees(left ? angle : -angle), axis: (x: 0, y: 1, z: 0),
                          anchor: left ? .trailing : .leading, perspective: 0.45)
        .shadow(color: .black.opacity(lit ? 0.10 : 0.04), radius: lit ? 12 : 6, y: 3)
        .zIndex(lit ? 1 : 0)
        .animation(Motion.smooth, value: lit)
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: lean)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(agent.map { "\(zone.name): \($0.name), \(status($0))" } ?? "\(zone.name): empty")
    }

    @ViewBuilder
    private func content(_ agent: Agent?, zone: Zone) -> some View {
        if let agent {
            NavigationLink(value: agent.id) {
                VStack(spacing: 10) {
                    BotView(agent: agent, mood: state.mood(for: agent), size: 80, look: zone == .left ? 0.4 : -0.4)
                    Text(agent.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(status(agent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(Motion.snappy, value: status(agent))
                }
                .padding(.horizontal, 12)
            }
            .buttonStyle(PressableStyle())
        } else {
            VStack(spacing: 8) {
                Circle()
                    .strokeBorder(Color(.systemGray3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                    .frame(width: 80, height: 80)
                    .overlay(Image(systemName: "plus").font(.title3).foregroundStyle(.tertiary))
                Text("Empty").font(.headline).foregroundStyle(.secondary)
            }
        }
    }

    /// You, at the spine.
    private var you: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(Color(.systemGray4)))
                .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
            Text("You").font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }

    private func status(_ a: Agent) -> String {
        if state.failing.contains(a.id) { return "Can't connect" }
        if state.activeId == a.id {
            switch state.phase {
            case .greeting: return "Saying hello"
            case .listening: return "Listening"
            case .thinking: return "Thinking"
            case .speaking: return "Speaking"
            case .idle: return "Tap the mic to talk"
            }
        }
        if state.focusedId == a.id { return "Nod to talk" }
        return "Idle"
    }
}
