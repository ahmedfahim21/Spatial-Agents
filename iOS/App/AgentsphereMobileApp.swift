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
            Tab("Agents", systemImage: "square.grid.2x2", value: .agents) { AgentsView() }
            Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView() }
        }
        .tint(.primary)
        // Conversations started anywhere but Find (which shows its own) slide up here.
        .sheet(isPresented: talking) {
            if let id = state.activeId {
                ConversationScreen(agentId: id).presentationDragIndicator(.visible)
            }
        }
        .onOpenURL { state.openURL($0) }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView { onboarded = true }
        }
        .onChange(of: onboarded, initial: true) { _, done in
            #if DEBUG
            // `-toolTest weather -toolArgs '{"days":1}'` runs one phone tool and logs the result.
            if let name = UserDefaults.standard.string(forKey: "toolTest") {
                Task {
                    try? await Task.sleep(for: .seconds(3))   // a location fix
                    let call = PhoneTools.Call(id: "test", name: name, arguments: Self.rawArgument("-toolArgs") ?? "{}")
                    print("Agentsphere: toolTest \(name) -> \(await state.phoneTools.run(call, allowed: Set(AgentTool.allCases)))")
                }
            }
            if UserDefaults.standard.bool(forKey: "sample") {
                state.loadSampleWorld(scene: state.sampleScene)
                return
            }
            #endif
            if done { state.start() }
        }
    }

    #if DEBUG
    /// The launch argument after `flag`, as typed (UserDefaults would parse it as a plist).
    private static func rawArgument(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        return args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    #endif

    private var talking: Binding<Bool> {
        Binding(get: { state.activeId != nil && state.findTargetId == nil && onboarded },
                set: { if !$0 { state.endConversation() } })
    }
}
