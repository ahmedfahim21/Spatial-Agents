import SwiftUI

struct SettingsView: View {
    @Environment(MobileState.self) private var state
    @AppStorage("onboarded") private var onboarded = true
    @State private var arranging = false
    @State private var confirmClearAll = false
    @State private var copiedAccount = false
    @State private var teaching = false

    var body: some View {
        @Bindable var state = state
        let loc = state.location
        NavigationStack {
            Form {
                Section("Head and gestures") {
                    LabeledContent(state.hasHeadData ? state.routeName : "AirPods", value: state.hasHeadData ? "Tracking" : "Not connected")
                    Toggle("Agents with me", isOn: $state.withMe).tint(.green)
                    Button("Arrange your space") { arranging = true }
                    Button {
                        teaching = true
                    } label: {
                        LabeledContent("Teach your gestures", value: state.gesturesLearned ? "Learnt" : "Not yet")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Sensitivity", value: state.gestureSensitivity < 0.85 ? "Firm" : state.gestureSensitivity > 1.2 ? "Light" : "Normal")
                        Slider(value: $state.gestureSensitivity, in: 0.5...2, step: 0.1) {
                            Text("Sensitivity")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise")
                        } maximumValueLabel: {
                            Image(systemName: "hare")
                        }
                    }
                    if state.gesturesLearned {
                        Button("Forget my gestures", role: .destructive) { state.resetGestures() }
                    }
                    NavigationLink {
                        LineupsView()
                    } label: {
                        LabeledContent("Times of day", value: state.activeLineup?.name ?? (state.lineups.isEmpty ? "Off" : "Usual pair"))
                    }
                }
                Section {
                    Picker("Nearby agents", selection: $state.announce) {
                        ForEach(MobileState.Announce.allCases) { Text($0.title).tag($0) }
                    }
                } header: { Text("Walking around") } footer: {
                    Text("With headphones in, walking into a place's area, Air Agents tells you who's there and asks if you want to talk. Double nod for yes, double shake for no. Works with your phone in your pocket.")
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
                    if let id = state.accountId {
                        Button {
                            UIPasteboard.general.string = id
                            copiedAccount = true
                        } label: {
                            LabeledContent("Account ID", value: copiedAccount ? "Copied" : String(id.prefix(8)) + "…")
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Copies your account ID")
                    }
                    Button("Show the introduction") { onboarded = false }
                }
            }
            // Ink for buttons; switches keep green, since an ink track hides the white knob in dark mode.
            .tint(.primary)
            .navigationTitle("Settings")
            .onAppear { state.refreshRoute() }
            .sheet(isPresented: $arranging) { SetupView() }
            .sheet(isPresented: $teaching) { GestureLessonView() }
        }
    }
}
