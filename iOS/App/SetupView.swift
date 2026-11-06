import SwiftUI

/// Three steps: set forward, arrange your agents in the six zones, then try looking at them.
struct SetupView: View {
    enum Step: Int, CaseIterable { case forward, arrange, tryIt }

    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .forward

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progress.padding(.top, 4)
                Group {
                    switch step {
                    case .forward: forward
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

    // MARK: 1. Forward

    private var forward: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Color(.secondarySystemGroupedBackground)).frame(width: 200, height: 200)
                VStack(spacing: 10) {
                    Image(systemName: "arrow.up").font(.system(size: 34, weight: .bold))
                    BotView(color: .cyan, shape: .circle, mood: state.hasHeadData ? .arrived : .idle, size: 80)
                }
            }
            Text("Look straight ahead").font(.title2.bold())
            Text("Sit or stand the way you usually work. This becomes the front of your space; your agents stay arranged around it and come with you when you move.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label("Keep Spatial Audio **Off** for Agentsphere in Control Center. The app places sounds itself.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(14)
                .card()
            Spacer()
            if !state.hasHeadData {
                Text("Waiting for AirPods head tracking…").font(.footnote).foregroundStyle(.orange)
            }
            Button("This is forward") {
                state.calibrateForward()
                state.haptics.tap(intensity: 0.8, sharpness: 0.5)
                step = .arrange
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!state.hasHeadData)
        }
    }

    // MARK: 2. Arrange

    private var arrange: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Place your agents").font(.title2.bold())
                Text("Drag them between zones. Tap one to hear it from there.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 18)
            SpaceStage(editing: true).frame(height: 340)
            if state.bodyAgents.isEmpty {
                Text("You don't have any personal agents yet. Create one with “With me”.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if !state.unzonedAgents.isEmpty {
                Text("These don't fit yet. Drag one onto a zone to swap it in.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(state.unzonedAgents) { a in
                        BotView(agent: a, size: 44).draggable(a.id.uuidString) { BotView(agent: a, size: 44) }
                    }
                }
            }
            Spacer()
            Button("Next") { step = .tryIt }.buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: 3. Try it

    private var tryIt: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Try looking around").font(.title2.bold())
                Text("Each agent notices when your gaze lands on it. Later, look at one and nod to talk.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 18)
            SpaceStage().frame(height: 340)
            Text(state.agent(state.focusedId).map { "Looking at \($0.name)" } ?? " ")
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
