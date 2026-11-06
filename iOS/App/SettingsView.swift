import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: MobileState
    @ObservedObject var location: LocationService

    var body: some View {
        NavigationStack {
            Form {
                Section("Head tracking") {
                    LabeledContent("AirPods", value: state.hasHeadData ? "Tracking" : "Not tracking")
                    Text(state.trackingStatus).font(.footnote).foregroundStyle(.secondary)
                    Toggle("Agents with me", isOn: $state.withMe)
                    Button("Recenter (face forward, then tap)") { state.recenter() }
                }
                Section("Audio") {
                    LabeledContent("Route", value: state.route)
                    LabeledContent("Stereo with mic open", value: state.highQualityMic ? "Yes" : "No (headset mode)")
                    if !state.voiceStatus.isEmpty { LabeledContent("Voice", value: state.voiceStatus) }
                    Button("Refresh") { state.refreshRoute() }
                }
                Section("Location") {
                    if let c = location.coordinate {
                        LabeledContent("Position", value: String(format: "%.5f, %.5f", c.latitude, c.longitude))
                        LabeledContent("Accuracy", value: "±\(Int(location.accuracy)) m")
                    }
                    if let h = location.heading { LabeledContent("Heading", value: "\(Int(h))° (±\(Int(location.headingAccuracy))°)") }
                    Toggle("Demo mode (simulated location)", isOn: Binding(
                        get: { location.simulated != nil },
                        set: { state.setDemoMode($0) }
                    ))
                    Text("Demo mode freezes your position so you can “walk” toward agents with a button.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Account") {
                    LabeledContent("Backend", value: Config.isConfigured ? (state.backendStatus.isEmpty ? "Connected" : state.backendStatus) : "Not configured")
                    if let id = Backend.shared.userId { LabeledContent("User", value: String(id.prefix(8))) }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
