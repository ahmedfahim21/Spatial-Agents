import SwiftUI

/// Your personal agents, arranged around your head. Look at one and nod to talk.
struct WithMeView: View {
    @Environment(MobileState.self) private var state
    @State private var arranging = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if state.bodyAgents.isEmpty {
                        EmptyWithMe()
                    } else {
                        if !state.calibrated { setupPrompt }
                        // Radar and caption follow your head; they're their own views so
                        // the rest of the screen doesn't redraw as you turn.
                        VStack(spacing: 18) {
                            Radar()
                            Caption()
                        }
                        agentList
                        Button("Arrange your space") { arranging = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("With me")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { state.calibrateForward() } label: { Image(systemName: "scope") }
                        .accessibilityLabel("Set forward to where you're looking")
                        .disabled(!state.hasHeadData)
                }
            }
            .navigationDestination(for: UUID.self) { AgentDetailView(agentId: $0) }
            .sheet(isPresented: $arranging) { SetupView() }
        }
    }

    private var setupPrompt: some View {
        Button { arranging = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "square.grid.3x2")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up your space").font(.headline)
                    Text("Choose forward and place your agents around you.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .card()
        }
        .buttonStyle(PressableStyle())
    }

    private var agentList: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.bodyAgents.enumerated()), id: \.element.id) { i, agent in
                if i > 0 { RowDivider(leading: 68) }
                NavigationLink(value: agent.id) {
                    HStack(spacing: 14) {
                        BotView(agent: agent, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.name).font(.body).foregroundStyle(.primary)
                            if !agent.greeting.isEmpty {
                                Text("“\(agent.greeting)”").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(state.zones[agent.id]?.name ?? "Waiting")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .card()
    }
}

/// What's happening around you, in a line, plus where you're facing.
private struct Caption: View {
    @Environment(MobileState.self) private var state

    var body: some View {
        let focused = state.agent(state.focusedId)
        let active = state.agent(state.activeId)
        let title: String = {
            if let active { return "Talking to \(active.name)" }
            if let focused { return "Nod to talk to \(focused.name)" }
            if state.hasHeadData { return "Look at an agent, then nod" }
            return "Put in your AirPods to look around"
        }()
        return VStack(spacing: 4) {
            Text(title)
                .font(.headline)
                .contentTransition(.opacity)
            Text(state.hasHeadData ? "Facing \(Int(normalize360(state.headYaw)))° · AirPods head tracking"
                                   : "They'll sit around your head. Turn to one and nod to talk.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.center)
        }
        .animation(Motion.snappy, value: title)
    }
}

/// Top-down view of you and your agents: front is up, your gaze is the cone.
private struct Radar: View {
    @Environment(MobileState.self) private var state
    private let radius: CGFloat = 112

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemGray4), lineWidth: 0.75)
                .frame(width: radius * 2, height: radius * 2)
            if state.hasHeadData {
                GazeCone()
                    .fill(RadialGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0)],
                                         center: .bottom, startRadius: 0, endRadius: radius * 1.1))
                    .frame(width: radius * 1.1, height: radius * 1.15)
                    .offset(y: -radius * 0.575)
                    .rotationEffect(.degrees(state.headYaw))
                    .transition(.opacity)
            }
            Circle()
                .fill(Color(.secondarySystemGroupedBackground))
                .frame(width: 44, height: 44)
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
            ForEach(state.bodyAgents) { agent in
                if let zone = state.zones[agent.id] {
                    placed(agent, zone)
                }
            }
        }
        .frame(width: radius * 2 + 64, height: radius * 2 + 64)
        .animation(Motion.smooth, value: state.zones)
        .animation(Motion.snappy, value: state.hasHeadData)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your agents around you")
    }

    /// Eye-level agents sit on the ring; agents above you sit further in (seen from above,
    /// something overhead is closer to you), slightly smaller.
    private func placed(_ agent: Agent, _ zone: Zone) -> some View {
        let r = zone.isUpper ? radius * 0.56 : radius
        let a = zone.azimuth * .pi / 180
        let size: CGFloat = zone.isUpper ? 42 : 52
        let focused = state.focusedId == agent.id
        return ZStack {
            FocusRing(active: focused, diameter: size + 14, lineWidth: 3, showsTrack: false)
            BotView(agent: agent, mood: state.mood(for: agent), size: size, look: -sin(a))
            if zone.isUpper {
                Image(systemName: "arrow.up")
                    .font(.system(size: 9, weight: .bold))
                    .padding(3)
                    .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    .offset(x: size * 0.42, y: -size * 0.42)
            }
        }
        .offset(x: sin(a) * r, y: -cos(a) * r)
        .animation(Motion.snappy, value: focused)
    }
}

/// A wedge pointing up from the bottom centre: where you're looking.
private struct GazeCone: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.12, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - r.width * 0.12, y: r.minY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.08))
        p.closeSubpath()
        return p
    }
}

private struct EmptyWithMe: View {
    @Environment(MobileState.self) private var state

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: -10) {
                BotView(color: .yellow, shape: .squircle, size: 56, look: 0.5)
                BotView(color: .blue, shape: .hexagon, size: 72)
                BotView(color: .green, shape: .drop, size: 56, look: -0.5)
            }
            .padding(.top, 48)
            VStack(spacing: 6) {
                Text("No agents with you yet").font(.title3.bold())
                Text("Personal agents travel with you, arranged around your head. Turn to one and it's there.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Create one") {
                state.startCreating(.withMe)
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.top, 6)
        }
        .padding(.horizontal, 12)
    }
}
