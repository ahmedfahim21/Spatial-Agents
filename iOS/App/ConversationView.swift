import SwiftUI

/// Talking to one agent: its face and state up top, the conversation, and a text box.
/// Presented as a sheet whenever a conversation is active.
struct ConversationScreen: View {
    @Environment(MobileState.self) private var state
    let agentId: UUID

    var body: some View {
        if let agent = state.agent(agentId) {
            VStack(spacing: 0) {
                header(agent)
                MessageList(agent: agent)
                InputBar(agent: agent)
            }
            .background(Color(.systemBackground))
        }
    }

    private func header(_ agent: Agent) -> some View {
        ZStack(alignment: .top) {
            HStack {
                Button("End") { state.endConversation() }
                    .buttonStyle(SecondaryButtonStyle(fullWidth: false))
                Spacer()
            }
            VStack(spacing: 6) {
                BotView(agent: agent, mood: state.mood(for: agent), size: 64)
                Text(agent.name).font(.headline)
                PhaseLabel(phase: state.phase, failing: state.failing.contains(agent.id))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

/// "Listening", "Thinking", "Speaking": what the agent is doing, in words.
struct PhaseLabel: View {
    let phase: ConversationPhase
    var failing = false

    var body: some View {
        HStack(spacing: 5) {
            if failing {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Can't reach its brain right now")
            } else {
                switch phase {
                case .idle: Text("Tap the mic to talk")
                case .greeting: Text("Saying hello")
                case .speaking:
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                    Text("Speaking")
                case .listening:
                    Image(systemName: "waveform").symbolEffect(.variableColor.iterative, options: .repeating)
                    Text("Listening")
                case .thinking: Text("Thinking…")
                }
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(failing ? Color.orange : phase == .listening ? Color.red : Color.secondary)
        .contentTransition(.opacity)
        .animation(Motion.snappy, value: phase)
    }
}

private struct MessageList: View {
    @Environment(MobileState.self) private var state
    let agent: Agent

    var body: some View {
        let messages = state.messages(for: agent.id)
        let hearing = state.activeId == agent.id && state.phase == .listening && !state.transcript.isEmpty
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(messages) { m in
                    MessageBubble(message: m)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: m.kind == .user ? .bottomTrailing : .bottomLeading)),
                                                removal: .opacity))
                }
                if hearing {
                    VStack(alignment: .trailing, spacing: 4) {
                        MessageBubble(message: ChatMessage(.user, state.transcript), ghost: true)
                        Text("Hearing you").font(.caption2).foregroundStyle(.secondary).padding(.trailing, 4)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .animation(Motion.snappy, value: messages.count)
            .animation(Motion.snappy, value: hearing)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    var ghost = false

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer(minLength: 56)
                Text(message.text)
                    .foregroundStyle(ghost ? Color.secondary : Color(.systemBackground))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(ghost ? Color(.systemGray6) : Color.primary, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
        case .agent:
            HStack {
                Group {
                    if message.text.isEmpty {
                        TypingDots()
                    } else {
                        Text(message.text)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                Spacer(minLength: 56)
            }
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        default:
            Text(message.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }
}

/// Three dots breathing while a reply is on its way.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
            .foregroundStyle(.secondary)
            .frame(height: 22)
        }
    }
}

private struct InputBar: View {
    @Environment(MobileState.self) private var state
    let agent: Agent
    @State private var typed = ""
    @FocusState private var typing: Bool

    private var canSend: Bool { !typed.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 10) {
            TextField("Message", text: $typed, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Capsule().strokeBorder(Color(.systemGray4)))
            if canSend {
                Button(action: send) { Image(systemName: "arrow.up") }
                    .buttonStyle(SendButtonStyle(active: true))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else if state.activeId == agent.id, state.phase == .idle {
                Button { state.resumeListening() } label: { Image(systemName: "mic.fill") }
                    .buttonStyle(SendButtonStyle(active: true))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                Button(action: send) { Image(systemName: "arrow.up") }
                    .buttonStyle(SendButtonStyle(active: false))
                    .disabled(true)
            }
        }
        .animation(Motion.snappy, value: canSend)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func send() {
        guard canSend else { return }
        state.send(typed, to: agent.id)
        typed = ""
        typing = false
    }
}

private struct SendButtonStyle: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(active ? Color(.systemBackground) : Color.secondary)
            .frame(width: 38, height: 38)
            .background(active ? Color.primary : Color(.systemGray5), in: Circle())
            .pressable(configuration.isPressed, scale: 0.92)
    }
}
