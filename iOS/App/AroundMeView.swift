import SwiftUI

/// Your personal agents, arranged in your space. Look at one for 3 seconds to talk.
struct AroundMeView: View {
    @EnvironmentObject var state: MobileState
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if !state.calibrated && !state.bodyAgents.isEmpty {
                    setupBanner
                }
                SpaceStage()
                    .frame(height: state.activeId == nil ? 340 : 230)
                    .animation(.easeInOut, value: state.activeId)
                if let a = state.agent(state.activeId) {
                    VStack(spacing: 4) {
                        Text(a.name).font(.headline)
                        PhaseLabel(phase: state.phase)
                    }
                    ConversationView(agent: a)
                } else {
                    PhaseLabel(phase: .idle)
                    if !state.hasHeadData {
                        Text(state.trackingStatus).font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).padding(.horizontal)
                    }
                    if state.bodyAgents.isEmpty {
                        Text("No agents with you yet. Create a personal agent and choose “With me”.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                    Spacer()
                }
            }
            .padding(.horizontal)
            .navigationTitle("With me")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSetup = true } label: { Image(systemName: "square.grid.3x2") }
                        .accessibilityLabel("Arrange your space")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { state.calibrateForward() } label: { Image(systemName: "scope") }
                        .accessibilityLabel("Set forward to where you're looking")
                }
                if state.activeId != nil {
                    ToolbarItem(placement: .topBarLeading) { Button("End") { state.endConversation() } }
                }
            }
            .sheet(isPresented: $showSetup) { SetupView().environmentObject(state).environmentObject(state.head) }
        }
    }

    private var setupBanner: some View {
        Button { showSetup = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up your space").font(.headline)
                    Text("Choose forward and place your agents around you.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
