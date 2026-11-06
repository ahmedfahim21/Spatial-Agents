import SwiftUI

/// Three steps: set forward, arrange your agents in the six zones, then try looking at them.
struct SetupView: View {
    enum Step: Int { case forward, arrange, tryIt }

    @EnvironmentObject var state: MobileState
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .forward

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                progress
                switch step {
                case .forward: forward
                case .arrange: arrange
                case .tryIt: tryIt
                }
            }
            .padding()
            .navigationTitle("Your space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .onAppear { state.arranging = true }
        .onDisappear { state.arranging = false }
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { i in
                Capsule().fill(i <= step.rawValue ? Color.cyan : Color.white.opacity(0.15)).frame(height: 4)
            }
        }
    }

    // MARK: Step 1

    private var forward: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle().fill(Color.cyan.opacity(0.12)).frame(width: 180, height: 180)
                Image(systemName: "person.and.arrow.left.and.arrow.right.outward")
                    .font(.system(size: 64)).foregroundStyle(.cyan)
                    .opacity(0)
                VStack(spacing: 8) {
                    Image(systemName: "arrow.up").font(.system(size: 40, weight: .bold)).foregroundStyle(.cyan)
                    Image(systemName: "person.fill").font(.system(size: 54)).foregroundStyle(.white)
                }
            }
            Text("Look straight ahead").font(.title2.bold())
            Text("Sit or stand the way you usually work. This direction becomes the front of your space. Your agents stay arranged around it and come with you when you move.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Label("In Control Center, keep Spatial Audio **Off** for Agentsphere. The app places sounds itself.", systemImage: "info.circle")
                .font(.footnote).foregroundStyle(.secondary).padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            Spacer()
            if !state.hasHeadData {
                Text("Waiting for AirPods head tracking…").font(.footnote).foregroundStyle(.orange)
            }
            Button {
                state.calibrateForward()
                state.haptics.tap(intensity: 0.8, sharpness: 0.5)
                withAnimation { step = .arrange }
            } label: {
                Text("This is forward").bold().frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!state.hasHeadData)
        }
    }

    // MARK: Step 2

    private var arrange: some View {
        VStack(spacing: 16) {
            Text("Place your agents").font(.title2.bold())
            Text("Drag them between zones. Tap one to hear it speak from there.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            SpaceStage(editing: true).frame(height: 340)
            if state.bodyAgents.isEmpty {
                Text("You don't have any personal agents yet. Create one in the Create tab and choose “With me”.")
                    .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            } else if !state.unzonedAgents.isEmpty {
                Text("\(state.unzonedAgents.count) more agent(s) don't fit in the six zones; drag one onto a zone to swap it in.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    ForEach(state.unzonedAgents) { a in
                        AgentOrb(agent: a, size: 44).draggable(a.id.uuidString) { AgentOrb(agent: a, size: 44) }
                    }
                }
            }
            Spacer()
            Button { withAnimation { step = .tryIt } } label: {
                Text("Next").bold().frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Step 3

    private var tryIt: some View {
        VStack(spacing: 16) {
            Text("Try looking around").font(.title2.bold())
            Text("Each agent lights up as your gaze lands on it. Later, hold your gaze for 3 seconds to start talking.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            SpaceStage().frame(height: 340)
            if let a = state.agent(state.focusedId) {
                Text("Looking at \(a.name)").font(.headline).foregroundStyle(a.tint)
            } else {
                Text(" ").font(.headline)
            }
            Spacer()
            HStack {
                Button("Back") { withAnimation { step = .arrange } }.buttonStyle(.bordered)
                Button {
                    state.finishSetup()
                    dismiss()
                } label: {
                    Text("Done").bold().frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
