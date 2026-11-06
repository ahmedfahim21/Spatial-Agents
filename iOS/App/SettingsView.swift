import SwiftUI

struct SettingsView: View {
    @Environment(MobileState.self) private var state
    @AppStorage("onboarded") private var onboarded = true
    @State private var arranging = false
    @State private var confirmClearAll = false

    var body: some View {
        @Bindable var state = state
        let loc = state.location
        NavigationStack {
            Form {
                Section("Head tracking") {
                    LabeledContent(state.hasHeadData ? state.routeName : "AirPods", value: state.hasHeadData ? "Tracking" : "Not connected")
                    Toggle("Agents with me", isOn: $state.withMe).tint(.green)
                    Picker("Glance to pick", selection: $state.glanceSize) {
                        Text("Small").tag(10.0)
                        Text("Medium").tag(14.0)
                        Text("Large").tag(20.0)
                    }
                    Button("Recenter") { state.calibrateForward() }
                        .disabled(!state.hasHeadData)
                    Button("Arrange your space") { arranging = true }
                }
                Section {
                    Picker("Nearby agents", selection: $state.announce) {
                        ForEach(MobileState.Announce.allCases) { Text($0.title).tag($0) }
                    }
                } header: { Text("Walking around") } footer: {
                    Text("With headphones in, agents near you introduce themselves from where they are, one at a time. Works with your phone in your pocket.")
                }
                Section("Audio") {
                    LabeledContent("Output", value: state.routeName)
                    LabeledContent("Stereo with mic open", value: state.highQualityMic ? "Yes" : "No")
                    LabeledContent("Voices", value: state.voiceStatus.isEmpty ? "Ready" : state.voiceStatus)
                }
                Section {
                    Toggle("Whisper on 0G", isOn: $state.whisper).tint(.green)
                } header: { Text("Speech recognition") } footer: {
                    Text(state.whisper
                         ? "What you say is transcribed by Whisper Large v3 on the 0G network: more accurate, about 3 seconds slower."
                         : "What you say is transcribed on your iPhone: instant, but less accurate.")
                }
                Section {
                    LabeledContent("Accuracy", value: loc.coordinate == nil ? "–" : "±\(Int(loc.accuracy)) m")
                    LabeledContent("Heading", value: loc.heading.map { "\(Int($0))° \(Words.compassShort($0)) ±\(Int(min(loc.headingAccuracy, 180)))°" } ?? "–")
                    LabeledContent("Indoors", value: loc.indoors ? "Yes (rough fix)" : "No")
                    LabeledContent("Standing still", value: loc.stationary ? "Yes (position held)" : "No")
                    Toggle("Demo mode", isOn: Binding(get: { loc.simulated != nil }, set: { state.setDemoMode($0) }))
                        .tint(.green)
                } header: { Text("Location") } footer: { Text("Simulates your location for stage demos.") }
                Section {
                    Button("Clear all chats", role: .destructive) { confirmClearAll = true }
                        .disabled(state.chattedAgents == 0)
                        .confirmationDialog("Clear all chats?", isPresented: $confirmClearAll, titleVisibility: .visible) {
                            Button("Clear all chats", role: .destructive) { state.clearAllChats() }
                        } message: {
                            Text("Every conversation goes back to just the agent's greeting. This can't be undone.")
                        }
                } header: { Text("Chats") } footer: {
                    Text(state.chattedAgents == 0 ? "No chats yet." : "You've talked to \(state.chattedAgents) agent\(state.chattedAgents == 1 ? "" : "s"). Chats are kept only on this iPhone.")
                }
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
