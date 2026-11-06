import SwiftUI

/// Everything you've made, in one place: the agents with you and the ones you've placed in
/// the world (any distance away). Tap one to talk to it, edit it, or see its shop; + makes a new one.
struct AgentsView: View {
    @Environment(MobileState.self) private var state
    @State private var path: [UUID] = []

    var body: some View {
        @Bindable var state = state
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if state.myAgents.isEmpty {
                        EmptyAgents { state.startCreating(.withMe) }
                    } else {
                        if !state.bodyAgents.isEmpty {
                            section("With me", state.bodyAgents)
                        }
                        if !placed.isEmpty {
                            section("Placed", placed)
                        }
                    }
                }
                .padding(.bottom, 24)
                .animation(Motion.snappy, value: state.myAgents.map(\.id))
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await state.refreshMine() }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { AgentDetailView(agentId: $0) }
        }
        .sheet(isPresented: $state.creating) {
            CreateView { created in
                state.creating = false
                // Show what you just made.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    path = [created.id]
                }
            }
        }
    }

    /// Your placed agents, nearest first.
    private var placed: [Agent] {
        state.placedAgents.sorted { (state.distance(to: $0) ?? .infinity) < (state.distance(to: $1) ?? .infinity) }
    }

    private var header: some View {
        HStack(alignment: .center) {
            ScreenTitle("Agents")
            Button { state.startCreating(state.createFlavor) } label: {
                Image(systemName: "plus").font(.system(size: 17, weight: .bold))
            }
            .buttonStyle(CircleButtonStyle())
            .accessibilityLabel("New agent")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func section(_ title: String, _ agents: [Agent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).padding(.horizontal, 16)
            VStack(spacing: 0) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { i, a in
                    if i > 0 { RowDivider(leading: 72) }
                    NavigationLink(value: a.id) { AgentRow(agent: a) }
                        .buttonStyle(PressableStyle())
                }
            }
            .card()
            .padding(.horizontal, 16)
        }
    }
}

/// One of your agents: face, name, what kind it is, and where it is.
private struct AgentRow: View {
    @Environment(MobileState.self) private var state
    let agent: Agent

    var body: some View {
        HStack(spacing: 14) {
            BotView(agent: agent, mood: state.mood(for: agent), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                AgentTitle(agent: agent, font: .body.weight(.semibold), badgeSize: 13, tappable: false)
                    .foregroundStyle(.primary)
                kind.font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(whereabouts).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var kind: some View {
        if !agent.isGeo {
            Text(agent.greeting.isEmpty ? "With you" : "“\(agent.greeting)”").lineLimit(1)
        } else if !agent.isPublic {
            Label("Only you", systemImage: "lock.fill").labelStyle(CompactLabel())
        } else if agent.pricing == "paid" {
            Label("Shop", systemImage: "bag.fill").labelStyle(CompactLabel())
        } else {
            Text("Public")
        }
    }

    private var whereabouts: String {
        if !agent.isGeo { return state.zones[agent.id]?.name ?? "" }
        if state.arrived.contains(agent.id) { return "Here" }
        return state.distance(to: agent).map(Words.distance) ?? ""
    }
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.caption)
            configuration.title
        }
    }
}

/// No agents yet: one clear way to start.
private struct EmptyAgents: View {
    let create: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            BotView(color: .cyan, shape: .circle, mood: .arrived, size: 72, seed: 0.3)
            Text("Make your first agent").font(.title3.bold())
            Text("Keep one with you, or place one somewhere for people to find and talk to.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New agent", action: create)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .card()
        .padding(.horizontal, 16)
    }
}
