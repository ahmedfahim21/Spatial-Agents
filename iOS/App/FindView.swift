import SwiftUI

/// Finding a placed agent, Find My style, then (once you're there) staring to talk.
/// Presented full screen from Explore.
struct FindView: View {
    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let agentId: UUID

    var body: some View {
        Group {
            if let agent = state.agent(agentId) {
                let here = state.arrived.contains(agent.id)
                ZStack {
                    if here {
                        ArrivedStage(agent: agent, close: { dismiss() })
                            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    } else {
                        FindingStage(agent: agent, close: { dismiss() })
                            .transition(.opacity.combined(with: .scale(scale: 1.03)))
                    }
                }
                .animation(Motion.smooth, value: here)
                .sheet(isPresented: talking) {
                    ConversationScreen(agentId: agent.id)
                        .presentationDragIndicator(.visible)
                }
            } else {
                VStack(spacing: 16) {
                    Text("This agent is no longer here.").foregroundStyle(.secondary)
                    Button("Close") { dismiss() }.buttonStyle(SecondaryButtonStyle(fullWidth: false))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .onAppear { state.findTargetId = agentId }
        .onDisappear { if state.findTargetId == agentId { state.findTargetId = nil } }
    }

    private var talking: Binding<Bool> {
        Binding(get: { state.activeId == agentId },
                set: { if !$0, state.activeId == agentId { state.endConversation() } })
    }
}

// MARK: - Finding

private struct FindingStage: View {
    @Environment(MobileState.self) private var state
    let agent: Agent
    let close: () -> Void

    var body: some View {
        let remaining = state.distance(to: agent).map { max(0, $0 - state.arrivalRadius(for: agent)) }
        let relative = state.screenArrow(to: agent)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    BotView(agent: agent, size: 28)
                    Text(agent.name).font(.headline)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(CircleButtonStyle())
                    .accessibilityLabel("Close")
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(remaining.map(Words.distance) ?? "–")
                    .font(.system(size: 72, weight: .bold))
                    .tracking(-2)
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.snappy, value: remaining.map { Int($0) })
                Text(directionText(relative))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(Motion.snappy, value: directionText(relative))
            }
            .padding(.top, 28)

            Spacer(minLength: 12)
            Dial(angle: relative ?? state.bearing(to: agent))
                .frame(maxWidth: .infinity)
            Spacer(minLength: 12)

            VStack(spacing: 14) {
                Text("Pulses speed up as you get closer. With AirPods in, follow its beacon.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                if state.location.simulated != nil {
                    Button("Walk 10 m closer (demo)") { state.demoStep(toward: agent) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }

    private func directionText(_ relative: Double?) -> String {
        if let relative { return Words.direction(relative) }
        if let b = state.bearing(to: agent) { return "to the \(Words.compass(b))" }
        return "Finding your location…"
    }
}

/// The agent and its focus ring. Its eyes follow your head, so it redraws as you turn;
/// kept apart from the rest of the screen, which doesn't.
private struct ArrivedBot: View {
    @Environment(MobileState.self) private var state
    let agent: Agent
    let focused: Bool

    var body: some View {
        ZStack {
            FocusRing(active: focused, diameter: 212)
            BotView(agent: agent, mood: state.mood(for: agent), size: 160, look: state.look(for: agent))
        }
    }
}

private struct VoiceDirection: View {
    @Environment(MobileState.self) private var state
    let agent: Agent

    var body: some View {
        if let relative = state.relativeAngle(agent.id) {
            Text("Its voice is \(Words.voiceDirection(relative)) · \(state.routeName)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

/// The precision-finding dial: a ring of dots that brightens toward the agent, and the arrow.
private struct Dial: View {
    /// Degrees clockwise from straight up; nil hides the arrow.
    let angle: Double?
    /// The arrow's displayed rotation, unwrapped so it never spins the long way round.
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - 6
                for i in 0..<48 {
                    let deg = Double(i) * 7.5
                    let off = angle.map { abs(normalizeAngle(deg - $0)) } ?? 180
                    let near = max(0, 1 - off / 55)
                    let dot = 2.4 + 2.6 * near
                    let a = (deg - 90) * .pi / 180
                    let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2)),
                             with: .color(.primary.opacity(0.18 + 0.82 * near)))
                }
            }
            if angle != nil {
                ArrowShape()
                    .fill(Color.primary)
                    .frame(width: 92, height: 116)
                    .rotationEffect(.degrees(shown))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                ProgressView()
            }
        }
        .frame(width: 300, height: 300)
        .onAppear { shown = angle ?? 0 }
        .onChange(of: angle) { _, new in
            guard let new else { return }
            withAnimation(Motion.smooth) { shown += normalizeAngle(new - shown) }
        }
    }
}

/// A navigation arrow, pointing up.
private struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY - r.height * 0.26))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p.applying(.identity)
    }
}

// MARK: - Arrived: look, then nod

private struct ArrivedStage: View {
    @Environment(MobileState.self) private var state
    let agent: Agent
    let close: () -> Void

    var body: some View {
        let focused = state.focusedId == agent.id
        VStack(spacing: 0) {
            ZStack {
                Text("Arrived").font(.headline).foregroundStyle(.secondary)
                HStack {
                    Button(action: close) { Image(systemName: "chevron.left") }
                        .buttonStyle(CircleButtonStyle())
                        .accessibilityLabel("Back")
                    Spacer()
                }
            }
            .padding(.top, 12)

            Spacer()
            ArrivedBot(agent: agent, focused: focused)
            VStack(spacing: 6) {
                Text(agent.name)
                    .font(.system(size: 28, weight: .bold))
                    .multilineTextAlignment(.center)
                Group {
                    if !state.hasHeadData {
                        Text("Tap Talk to start")
                    } else if focused {
                        Text("Nod to talk")
                    } else {
                        Text("Look toward \(agent.name)")
                    }
                }
                .font(.headline)
                .contentTransition(.opacity)
                Text(state.hasHeadData ? "Shake your head to end the conversation" : "Put in your AirPods to talk hands-free")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 28)
            .animation(Motion.snappy, value: focused)
            Spacer()

            VStack(spacing: 14) {
                if state.hasHeadData { VoiceDirection(agent: agent) }
                if state.hasHeadData {
                    Button { state.wake(agent) } label: { Label("Talk instead", systemImage: "mic.fill") }
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button { state.wake(agent) } label: { Label("Talk", systemImage: "mic.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }
}
