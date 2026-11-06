import SwiftUI

@main
struct AgentsphereMobileApp: App {
    @State private var state = MobileState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
        }
    }
}

struct RootView: View {
    @Environment(MobileState.self) private var state
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        @Bindable var state = state
        TabView(selection: $state.screen) {
            Tab("Explore", systemImage: "safari", value: .explore) { ExploreView() }
            Tab("With me", systemImage: "eye", value: .withMe) { WithMeView() }
            Tab("Create", systemImage: "plus", value: .create) { CreateView() }
            Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView() }
        }
        .tint(.primary)
        // Conversations started anywhere but Find (which shows its own) slide up here.
        .sheet(isPresented: talking) {
            if let id = state.activeId {
                ConversationScreen(agentId: id).presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView { onboarded = true }
        }
        .onChange(of: onboarded, initial: true) { _, done in
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "sample") {
                state.loadSampleWorld(scene: state.sampleScene)
                return
            }
            #endif
            if done { state.start() }
        }
    }

    private var talking: Binding<Bool> {
        Binding(get: { state.activeId != nil && state.findTargetId == nil && onboarded },
                set: { if !$0 { state.endConversation() } })
    }
}
