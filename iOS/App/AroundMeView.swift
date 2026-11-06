import SwiftUI

/// Your body-anchored agents in a ring around your head. Look at one for 3 seconds to talk.
struct AroundMeView: View {
    @EnvironmentObject var state: MobileState
    @EnvironmentObject var head: HeadMotion
    @State private var showing: Agent?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                radar
                    .frame(height: 300)
                    .padding(.top)
                if let a = state.agent(state.activeId) {
                    VStack(spacing: 4) {
                        Text(a.name).font(.headline)
                        PhaseLabel(phase: state.phase)
                    }
                    ConversationView(agent: a)
                } else {
                    PhaseLabel(phase: .idle)
                    if !state.hasHeadData {
                        Text(state.trackingStatus).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                    }
                    List {
                        ForEach(state.bodyAgents) { a in
                            Button { state.wake(a) } label: {
                                HStack(spacing: 12) {
                                    AgentOrb(agent: a, size: 38)
                                    VStack(alignment: .leading) {
                                        Text(a.name).foregroundStyle(.primary)
                                        Text(a.greeting).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                        .onDelete { idx in
                            let agents = idx.map { state.bodyAgents[$0] }
                            Task { for a in agents { await state.delete(a) } }
                        }
                        if state.bodyAgents.isEmpty {
                            Text("No agents with you yet. Create a personal agent and choose “With me”.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("With me")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { state.recenter() } label: { Image(systemName: "scope") }
                }
                if state.activeId != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("End") { state.endConversation() }
                    }
                }
            }
        }
    }

    /// Top-down view: you in the middle, facing up; agents placed where you hear them.
    private var radar: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size * 0.38
            ZStack {
                Circle().stroke(Color.white.opacity(0.08), lineWidth: 1).frame(width: r * 2, height: r * 2)
                // Focus cone straight ahead.
                Path { p in
                    p.move(to: CGPoint(x: size / 2, y: size / 2))
                    p.addArc(center: CGPoint(x: size / 2, y: size / 2), radius: r * 1.15,
                             startAngle: .degrees(-90 - 22), endAngle: .degrees(-90 + 22), clockwise: false)
                    p.closeSubpath()
                }
                .fill(RadialGradient(colors: [Color.cyan.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: r * 1.15))
                .frame(width: size, height: size)
                Image(systemName: "person.fill").font(.title).foregroundStyle(.white.opacity(0.8))
                ForEach(state.talkable) { a in
                    if let rel = state.relativeAngle(a.id) {
                        AgentOrb(agent: a, size: 52,
                                 stare: state.focusedId == a.id ? state.stareProgress : 0,
                                 active: state.activeId == a.id, focused: state.focusedId == a.id)
                            .position(x: size / 2 + CGFloat(sin(rel * .pi / 180)) * r,
                                      y: size / 2 - CGFloat(cos(rel * .pi / 180)) * r)
                            .onTapGesture { state.wake(a) }
                    }
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity)
        }
    }
}
