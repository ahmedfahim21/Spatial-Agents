import SwiftUI

/// An agent's avatar: glows while you stare at it, and pulses while it's talking to you.
struct AgentOrb: View {
    let agent: Agent
    var size: CGFloat = 56
    var stare: Double = 0
    var active = false
    var focused = false

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(agent.tint.opacity(active ? 0.55 : 0.18 + 0.4 * stare))
                .blur(radius: size * (active ? 0.35 : 0.2 + 0.3 * stare))
                .scaleEffect(active && pulse ? 1.35 : 1.1)
            Circle()
                .fill(LinearGradient(colors: [agent.tint, agent.tint.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle()
                .trim(from: 0, to: stare)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(-5)
                .opacity(stare > 0 && !active ? 1 : 0)
            Circle().stroke(Color.white.opacity(focused || active ? 0.9 : 0.15), lineWidth: focused || active ? 2 : 1)
            Text(agent.symbol)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.15), value: stare)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true } }
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct PhaseLabel: View {
    let phase: ConversationPhase
    var body: some View {
        HStack(spacing: 6) {
            switch phase {
            case .idle: Image(systemName: "eye"); Text("Look at an agent for 3 seconds")
            case .greeting, .speaking: Image(systemName: "waveform"); Text("Speaking")
            case .listening: Image(systemName: "mic.fill").foregroundStyle(.red); Text("Listening — just talk")
            case .thinking: ProgressView().controlSize(.mini); Text("Thinking")
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

/// The conversation with one agent: bubbles, your live words, and a text box.
struct ConversationView: View {
    @EnvironmentObject var state: MobileState
    let agent: Agent
    @State private var typed = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(state.messages(for: agent.id)) { m in
                            MessageBubble(message: m, tint: agent.tint).id(m.id)
                        }
                        if state.activeId == agent.id, state.phase == .listening, !state.transcript.isEmpty {
                            MessageBubble(message: ChatMessage(.user, state.transcript), tint: agent.tint, ghost: true)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding()
                }
                .onChange(of: state.messages(for: agent.id).last?.text) { _, _ in withAnimation { proxy.scrollTo("end") } }
                .onChange(of: state.transcript) { _, _ in proxy.scrollTo("end") }
                .onAppear { proxy.scrollTo("end") }
            }
            HStack {
                TextField("Message \(agent.name)", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(sendTyped)
                Button(action: sendTyped) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
    }

    private func sendTyped() {
        state.send(typed, to: agent.id)
        typed = ""
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let tint: Color
    var ghost = false

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 50)
                Text(message.text)
                    .italic(ghost)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(ghost ? 0.4 : 0.9), in: RoundedRectangle(cornerRadius: 16))
            }
        case .agent:
            HStack {
                Text(message.text.isEmpty ? "…" : message.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 50)
            }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
        default:
            Text(message.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }
}
