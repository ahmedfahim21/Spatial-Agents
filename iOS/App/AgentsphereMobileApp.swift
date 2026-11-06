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
        TabView(selection: $state.screen) {
            Tab("Explore", systemImage: "location.north.circle", value: .explore) { ExploreView(location: state.location) }
            Tab("With me", systemImage: "person.wave.2", value: .withMe) { AroundMeView() }
            Tab("Create", systemImage: "plus.circle", value: .create) { CreateView() }
            Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView(location: state.location) }
        }
        .tint(.cyan)
    }
}
