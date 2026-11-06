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
                            TimeOfDayChip()
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
            .navigationDestination(for: UUID.self) { AgentDetailView(agentId: $0) }
            .sheet(isPresented: $arranging) { SetupView() }
            #if DEBUG
            .onAppear { if UserDefaults.standard.string(forKey: "setupStep") != nil { arranging = true } }
            #endif
        }
    }

    private var setupPrompt: some View {
        Button { arranging = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up your space").font(.headline)
                    Text("Choose who sits on your left and who sits on your right.")
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
                        Text(state.zones[agent.id]?.name ?? "Not in a window")
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

/// Which pair is in your windows: a time of day, or your usual pair. Opens the times.
private struct TimeOfDayChip: View {
    @Environment(MobileState.self) private var state

    var body: some View {
        NavigationLink {
            LineupsView()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.activeLineup == nil ? "clock" : "clock.fill")
                if let l = state.activeLineup {
                    Text(l.name).fontWeight(.semibold)
                    Text("until \(Lineup.clock(l.end))").foregroundStyle(.secondary)
                } else {
                    Text(state.lineups.isEmpty ? "Set pairs for times of day" : "Usual pair")
                }
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .frame(maxWidth: .infinity)
        .padding(.bottom, -14)
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
            if let focused { return "Double nod or tap to talk to \(focused.name)" }
            if state.hasHeadData { return "Turn left or right to pick an agent" }
            return "Tap an agent to talk"
        }()
        return VStack(spacing: 4) {
            Text(title)
                .font(.headline)
                .contentTransition(.opacity)
            Text(state.hasHeadData ? "A quick turn of your head, from wherever you're facing, picks that side. Double nod or tap to talk; double shake or say bye to end."
                                   : "Put in your AirPods to pick one with a turn of your head and a double nod.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.center)
        }
        .animation(Motion.snappy, value: title)
    }
}

/// Top-down view of you and your agents, left and right. The cone points at the one you picked.
private struct Radar: View {
    @Environment(MobileState.self) private var state
    private let radius: CGFloat = 112

    var body: some View {
        ZStack {
            Circle().stroke(Color(.systemGray4), lineWidth: 0.75)
                .frame(width: radius * 2, height: radius * 2)
            if let side = state.pickedSide, state.agent(in: side) != nil {
                GazeCone()
                    .fill(RadialGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0)],
                                         center: .bottom, startRadius: 0, endRadius: radius * 1.1))
                    .frame(width: radius * 1.1, height: radius * 1.15)
                    .offset(y: -radius * 0.575)
                    .rotationEffect(.degrees(side.azimuth))
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
        .animation(Motion.snappy, value: state.pickedSide)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your agents around you")
    }

    /// Each window's agent sits on the ring at its side. The picked one grows; tap one to talk.
    private func placed(_ agent: Agent, _ zone: Zone) -> some View {
        let r = radius
        let a = zone.azimuth * .pi / 180
        let size: CGFloat = 52
        let focused = state.focusedId == agent.id
        let dimmed = state.focusedId != nil && !focused
        return Button {
            if state.activeId != agent.id { state.wake(agent) }
        } label: {
            ZStack {
                FocusRing(active: focused, diameter: size + 14, lineWidth: 3, showsTrack: false)
                BotView(agent: agent, mood: state.mood(for: agent), size: size, look: -sin(a))
            }
        }
        .buttonStyle(PressableStyle())
        .scaleEffect(focused ? 1.5 : dimmed ? 0.85 : 1)
        .opacity(dimmed ? 0.55 : 1)
        .offset(x: sin(a) * r, y: -cos(a) * r)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: focused)
        .animation(Motion.snappy, value: dimmed)
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
                Text("Personal agents travel with you, one on your left and one on your right. Turn toward one and it's there.")
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
