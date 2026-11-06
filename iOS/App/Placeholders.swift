import SwiftUI

struct ExploreView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Nearby agents", systemImage: "location.north.circle",
                                   description: Text("Agents placed around you will appear here."))
                .navigationTitle("Explore")
        }
    }
}

struct AroundMeView: View {
    @EnvironmentObject var state: MobileState
    @EnvironmentObject var head: HeadMotion

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                ZStack {
                    Circle().stroke(.white.opacity(0.15), lineWidth: 2).frame(width: 220, height: 220)
                    Image(systemName: "location.north.fill")
                        .font(.system(size: 54)).foregroundStyle(.cyan)
                        .rotationEffect(.degrees(head.yaw))
                }
                Text(String(format: "Head %.0f°  ·  pitch %.0f°", head.yaw, head.pitch)).monospacedDigit()
                Text(state.trackingStatus).font(.footnote).foregroundStyle(.secondary)
                if let g = state.lastGesture { Text("Gesture: \(g.rawValue)").font(.headline) }
                HStack {
                    Button("Recenter") { state.recenter() }.buttonStyle(.bordered)
                    Button("Spatial test") { state.runSpatialTest() }.buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("With me")
        }
    }
}

struct CreateView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Create an agent", systemImage: "plus.circle")
                .navigationTitle("Create")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: MobileState
    var body: some View {
        NavigationStack {
            Form {
                Section("Audio") {
                    LabeledContent("Route", value: state.route)
                    LabeledContent("Stereo with mic open", value: state.highQualityMic ? "Yes" : "No (headset mode)")
                    Button("Refresh") { state.refreshRoute() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
