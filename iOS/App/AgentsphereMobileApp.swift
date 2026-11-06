import SwiftUI

@main
struct AgentsphereMobileApp: App {
    @StateObject private var state = MobileState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .environmentObject(state.head)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: MobileState

    var body: some View {
        TabView {
            Tab("Explore", systemImage: "location.north.circle") { ExploreView() }
            Tab("With me", systemImage: "person.wave.2") { AroundMeView() }
            Tab("Create", systemImage: "plus.circle") { CreateView() }
            Tab("Settings", systemImage: "gearshape") { SettingsView() }
        }
        .tint(.cyan)
    }
}
