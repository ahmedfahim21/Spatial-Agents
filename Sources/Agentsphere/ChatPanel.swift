import SwiftUI

/// The conversation with the agent you're facing (or the one you clicked).
struct ChatPanel: View {
    @EnvironmentObject var state: AppState

    private var agent: AgentSession? { state.target ?? state.sessions.first { $0.id == state.selectedId } }

    var body: some View {
        VStack(spacing: 0) {
            if let agent {
                header(agent)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if agent.messages.isEmpty {
                                Text("No messages yet. Face \(agent.name) and speak, or type below.")
                                    .font(.callout).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.top, 40)
                            }
                            ForEach(agent.messages) { MessageRow(message: $0).id($0.id) }
                            liveRows(agent)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(14)
                    }
                    .onChange(of: agent.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom") } }
                    .onChange(of: agent.id) { _, _ in proxy.scrollTo("bottom") }
                    .onChange(of: state.transcript) { _, _ in proxy.scrollTo("bottom") }
                    .onAppear { proxy.scrollTo("bottom") }
                }
                Divider()
                composer(agent)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("Add a Claude session (⌘N), then face it to chat.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ a: AgentSession) -> some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor(a.status)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.name).font(.headline)
                Text(a.title.isEmpty ? a.directory.path : a.title)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(a.status.rawValue).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Things in progress: Claude working, your words being heard, a send about to go.
    @ViewBuilder private func liveRows(_ a: AgentSession) -> some View {
        if a.status == .working {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Working…").font(.caption).foregroundStyle(.secondary)
            }
        }
        if state.isListening, state.target?.id == a.id {
            Bubble(text: state.transcript.isEmpty ? "Listening…" : state.transcript, mine: true, ghost: true)
        }
        if let p = state.pendingSend, p.target == a.id {
            VStack(alignment: .trailing, spacing: 4) {
                Bubble(text: p.text, mine: true, ghost: true)
                HStack {
                    Text("Sending… shake to cancel").font(.caption2).foregroundStyle(.secondary)
                    Button("Cancel") { state.cancelPendingSend() }.controlSize(.small)
                    Button("Send now") { state.commitPendingSend() }.controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func composer(_ a: AgentSession) -> some View {
        HStack {
            TextField("Message \(a.name)…", text: $state.typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit { state.sendTyped() }
            Button { state.sendTyped() } label: { Image(systemName: "paperplane.fill") }
                .disabled(state.typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    private func statusColor(_ s: AgentStatus) -> Color {
        switch s {
        case .idle: return .gray
        case .working: return .orange
        case .asking: return .purple
        case .waiting: return .green
        case .error: return .red
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.kind {
        case .user:
            Bubble(text: message.text, mine: true)
        case .agent:
            Bubble(text: message.text, mine: false)
        case .tool(let name):
            HStack(spacing: 6) {
                Image(systemName: icon(for: name)).font(.caption)
                Text(name).font(.caption.weight(.semibold))
                if !message.text.isEmpty {
                    Text(message.text).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        case .permission(let st):
            HStack(spacing: 6) {
                Image(systemName: st == .asking ? "hand.raised.fill" : st == .approved ? "checkmark.circle.fill" : "xmark.octagon.fill")
                Text(st == .asking ? "Asks: \(message.text) — nod or shake" : (st == .approved ? "Approved: " : "Denied: ") + message.text)
                    .font(.callout)
            }
            .foregroundStyle(st == .asking ? Color.purple : st == .approved ? Color.green : Color.red)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background((st == .asking ? Color.purple : st == .approved ? Color.green : Color.red).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 8))
        case .note, .order:
            Text(message.text).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        case .error:
            Label(message.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red)
        }
    }

    private func icon(for tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit", "MultiEdit", "Write": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task": return "person.2"
        default: return "wrench.and.screwdriver"
        }
    }
}

struct Bubble: View {
    let text: String
    let mine: Bool
    var ghost = false

    private var rendered: AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            Text(rendered)
                .textSelection(.enabled)
                .italic(ghost)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .background(mine ? Color.accentColor.opacity(ghost ? 0.45 : 1) : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 14))
            if !mine { Spacer(minLength: 40) }
        }
    }
}
