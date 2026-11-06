import SwiftUI

/// Two steps: choose who sits in your left and right windows, then try turning toward them.
struct SetupView: View {
    enum Step: Int, CaseIterable { case arrange, tryIt }

    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = {
        #if DEBUG
        // `-setupStep arrange` opens straight to a step, for checking screens without AirPods.
        if let s = UserDefaults.standard.string(forKey: "setupStep"), let i = ["arrange", "try"].firstIndex(of: s) {
            return Step(rawValue: i) ?? .arrange
        }
        #endif
        return .arrange
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress.padding(.top, 4)
                Group {
                    switch step {
                    case .arrange: arrange
                    case .tryIt: tryIt
                    }
                }
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .animation(Motion.smooth, value: step)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Your space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .tint(.primary)
        .onAppear { state.arranging = true }
        .onDisappear { state.arranging = false }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { s in
                Capsule()
                    .fill(s.rawValue <= step.rawValue ? Color.primary : Color(.systemGray4))
                    .frame(height: 4)
            }
        }
    }

    // MARK: 2. Arrange

    private var arrange: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Choose your windows").font(.title2.bold())
                Text("One agent on your left, one on your right. Front stays clear. Tap a window to choose who sits there.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 18)
            SpaceStage(editing: true).frame(height: 260)
            if state.bodyAgents.isEmpty {
                Text("You don't have any personal agents yet. Create one with “With me”.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !state.unzonedAgents.isEmpty {
                Text("Not in a window: \(state.unzonedAgents.map(\.name).formatted(.list(type: .and))). \(state.unzonedAgents.count == 1 ? "It waits" : "They wait") in Agents until you swap \(state.unzonedAgents.count == 1 ? "it" : "them") in.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Label("Keep Spatial Audio **Off** for Air Agents in Control Center. The app places sounds itself.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(14)
                .card()
            Spacer()
            Button("Next") { step = .tryIt }.buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: 3. Try it

    private var tryIt: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Try turning").font(.title2.bold())
                Text("A quick turn left or right, from wherever you're facing, picks that side's agent. Later, double nod to talk.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 18)
            SpaceStage().frame(height: 260)
            Text(state.agent(state.focusedId).map { "Picked \($0.name)" } ?? " ")
                .font(.headline)
                .contentTransition(.opacity)
                .animation(Motion.snappy, value: state.focusedId)
            Spacer()
            HStack(spacing: 10) {
                Button("Back") { step = .arrange }.buttonStyle(SecondaryButtonStyle(fullWidth: false))
                Button("Done") {
                    state.finishSetup()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}
