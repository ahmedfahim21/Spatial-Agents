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
                        // The book and caption follow your head; they're their own views so
                        // the rest of the screen doesn't redraw as you turn.
                        VStack(spacing: 18) {
                            BookView()
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
                    Text("Choose forward, and who sits in your left and right windows.")
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

/// What's happening around you, in a line, plus where you're facing.
private struct Caption: View {
    @Environment(MobileState.self) private var state

    var body: some View {
        let focused = state.agent(state.focusedId)
        let active = state.agent(state.activeId)
        let title: String = {
            if let active { return "Talking to \(active.name)" }
            if let focused { return "Nod to talk to \(focused.name)" }
            if state.hasHeadData { return "Glance left or right, then nod" }
            return "Put in your AirPods to look around"
        }()
        return VStack(spacing: 4) {
            Text(title)
                .font(.headline)
                .contentTransition(.opacity)
            Text(state.hasHeadData ? "A small turn of the head picks a side, whichever way you're facing."
                                   : "They sit just left and right of you. Glance at one and nod to talk.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.center)
        }
        .animation(Motion.snappy, value: title)
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
