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
        .overlay(alignment: .top) { InviteBanner() }
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

/// "Two places around you. Want to talk to one?" on screen too: the names can be tapped.
private struct InviteBanner: View {
    @Environment(MobileState.self) private var state

    var body: some View {
        Group {
            if let invite = state.invite {
                let agents = invite.ids.compactMap(state.agent)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(invite.step == .choosing ? "Which one?"
                                 : agents.count == 1 ? "You're at \(agents.first?.name ?? "")"
                                 : "\(Words.count(agents.count).capitalized) places around you")
                                .font(.headline)
                            Text(invite.step == .choosing ? "Say its name, or tap it" : "Double nod for yes · double shake for no")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button { state.endInvite(declined: true) } label: { Image(systemName: "xmark") }
                            .buttonStyle(CircleButtonStyle())
                            .accessibilityLabel("No thanks")
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(agents) { a in
                                Button { state.acceptInvite(a.id) } label: {
                                    HStack(spacing: 8) {
                                        BotView(agent: a, size: 26)
                                        Text(a.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    }
                                    .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 6)
                                    .background(Color(.systemGray6), in: Capsule())
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.smooth, value: state.invite)
    }
}
