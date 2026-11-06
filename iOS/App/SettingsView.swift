import SwiftUI

struct SettingsView: View {
    @Environment(MobileState.self) private var state
    @AppStorage("onboarded") private var onboarded = true
    @State private var arranging = false

    var body: some View {
        @Bindable var state = state
        let loc = state.location
        NavigationStack {
            Form {
                Section("Head tracking") {
                    LabeledContent(state.hasHeadData ? state.routeName : "AirPods", value: state.hasHeadData ? "Tracking" : "Not connected")
                    Toggle("Agents with me", isOn: $state.withMe).tint(.green)
                    Button("Recenter") { state.calibrateForward() }
                        .disabled(!state.hasHeadData)
                    Button("Arrange your space") { arranging = true }
                }
                Section("Audio") {
                    LabeledContent("Output", value: state.routeName)
                    LabeledContent("Stereo with mic open", value: state.highQualityMic ? "Yes" : "No")
                    LabeledContent("Voices", value: state.voiceStatus.isEmpty ? "Ready" : state.voiceStatus)
                }
                Section {
                    LabeledContent("Accuracy", value: loc.coordinate == nil ? "–" : "±\(Int(loc.accuracy)) m")
                    LabeledContent("Heading", value: loc.heading.map { "\(Int($0))° \(Words.compassShort($0))" } ?? "–")
                    Toggle("Demo mode", isOn: Binding(get: { loc.simulated != nil }, set: { state.setDemoMode($0) }))
                        .tint(.green)
                } header: { Text("Location") } footer: { Text("Simulates your location for stage demos.") }
                WalletSection()
                Section("Account") {
                    LabeledContent("Server", value: !Config.isConfigured ? "Not configured" : state.backendStatus.isEmpty ? "Connected" : "Offline")
                    Button("Show the introduction") { onboarded = false }
                }
            }
            // Ink for buttons; switches keep green, since an ink track hides the white knob in dark mode.
            .tint(.primary)
            .navigationTitle("Settings")
            .onAppear { state.refreshRoute() }
            .sheet(isPresented: $arranging) { SetupView() }
        }
    }
}
