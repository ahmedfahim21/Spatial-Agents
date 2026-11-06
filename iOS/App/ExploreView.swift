import CoreLocation
import SwiftUI

/// Agents placed in the world near you, nearest first.
struct ExploreView: View {
    @EnvironmentObject var state: MobileState
    @ObservedObject private var loc: LocationService
    enum Mode: String, CaseIterable { case map = "Map", list = "List" }
    @State private var mode: Mode = .map
    @State private var path: [UUID] = []

    init(location: LocationService) { _loc = ObservedObject(wrappedValue: location) }

    private var sorted: [Agent] {
        state.nearby.sorted { (state.distance(to: $0) ?? .infinity) < (state.distance(to: $1) ?? .infinity) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if mode == .map {
                    ExploreMap(location: loc) { path.append($0) }
                        .safeAreaInset(edge: .top) { mapStatus }
                } else {
                    list
                }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) { ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.segmented).frame(width: 160)
                }
            }
            .navigationDestination(for: UUID.self) { id in FindView(agentId: id, location: loc) }
            .task { await state.refreshNearby(force: true) }
        }
    }

    /// The same notices as the list, compact over the map.
    @ViewBuilder private var mapStatus: some View {
        let notices = VStack(alignment: .leading, spacing: 6) { statusSection }
            .font(.footnote)
        notices
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .opacity(hasNotice ? 1 : 0)
    }

    private var hasNotice: Bool {
        !Config.isConfigured || loc.coordinate == nil || !state.backendStatus.isEmpty || loc.simulated != nil
            || loc.isPoorFix || loc.authorization == .denied
    }

    private var list: some View {
            List {
                statusSection
                if !sorted.isEmpty {
                    Section("Nearby") {
                        ForEach(sorted) { a in
                            NavigationLink(value: a.id) { NearbyRow(agent: a, location: loc) }
                        }
                    }
                } else if loc.coordinate != nil, Config.isConfigured, !state.loading {
                    ContentUnavailableView("No agents here yet", systemImage: "mappin.slash",
                                           description: Text("Create one and leave it here for others to find."))
                        .listRowBackground(Color.clear)
                }
            }
            .refreshable { await state.refreshNearby(force: true) }
    }

    @ViewBuilder private var statusSection: some View {
        if !Config.isConfigured {
            Label("Connect the backend in Config.swift to see agents.", systemImage: "server.rack").foregroundStyle(.orange)
        } else if loc.authorization == .denied || loc.authorization == .restricted {
            Label("Location is off. Allow it in Settings to find agents.", systemImage: "location.slash").foregroundStyle(.orange)
        } else if loc.coordinate == nil {
            Label("Finding your location…", systemImage: "location")
        }
        if !state.backendStatus.isEmpty {
            Label(state.backendStatus, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.footnote)
        }
        if loc.simulated != nil {
            Label("Demo mode: simulated location", systemImage: "theatermasks").foregroundStyle(.purple).font(.footnote)
        } else if loc.isPoorFix, loc.coordinate != nil {
            Label("GPS is rough here (±\(Int(loc.accuracy)) m). Arrival is more forgiving.", systemImage: "location.circle")
                .foregroundStyle(.secondary).font(.footnote)
        }
    }
}

struct NearbyRow: View {
    @EnvironmentObject var state: MobileState
    let agent: Agent
    @ObservedObject var location: LocationService

    var body: some View {
        HStack(spacing: 14) {
            AgentOrb(agent: agent, size: 46, active: state.activeId == agent.id)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.headline)
                HStack(spacing: 6) {
                    if agent.isMine == true && !agent.isPublic { Badge(text: "Only you", color: .purple) }
                    Badge(text: agent.pricing == "paid" ? "Paid" : "Free", color: .green)
                    if state.arrived.contains(agent.id) { Badge(text: "Here", color: .cyan) }
                }
            }
            Spacer()
            VStack(spacing: 2) {
                if let rot = state.screenArrow(to: agent) {
                    Image(systemName: "location.north.fill").rotationEffect(.degrees(rot)).foregroundStyle(agent.tint)
                }
                if let d = state.distance(to: agent) {
                    Text(GeoMath.describe(distance: d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// Find My-style: big arrow and distance, haptics and a beacon; on arrival, stare to talk.
struct FindView: View {
    @EnvironmentObject var state: MobileState
    let agentId: UUID
    @ObservedObject var location: LocationService

    var body: some View {
        if let a = state.agent(agentId) {
            VStack(spacing: 0) {
                if state.arrived.contains(a.id) {
                    arrivedHeader(a)
                    Divider()
                    ConversationView(agent: a)
                } else {
                    finding(a)
                }
            }
            .navigationTitle(a.name)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { state.findTargetId = a.id }
            .onDisappear { if state.findTargetId == a.id { state.findTargetId = nil } }
        } else {
            ContentUnavailableView("Agent unavailable", systemImage: "questionmark.circle")
        }
    }

    private func finding(_ a: Agent) -> some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle().fill(a.tint.opacity(0.12)).frame(width: 260, height: 260)
                Circle().stroke(a.tint.opacity(0.35), lineWidth: 2).frame(width: 260, height: 260)
                if let rot = state.screenArrow(to: a) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 120, weight: .heavy))
                        .foregroundStyle(a.tint)
                        .rotationEffect(.degrees(rot))
                        .animation(.easeOut(duration: 0.25), value: rot)
                } else {
                    ProgressView()
                }
            }
            if let d = state.distance(to: a) {
                Text(GeoMath.describe(distance: max(0, d - state.arrivalRadius(for: a))))
                    .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                Text("to \(a.name)").font(.title3).foregroundStyle(.secondary)
            }
            Text("Feel the pulses speed up as you get closer. With AirPods in, listen for its beacon.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
            if location.simulated != nil {
                Button { state.demoStep(toward: a) } label: { Label("Walk 10 m closer", systemImage: "figure.walk") }
                    .buttonStyle(.borderedProminent).padding(.bottom)
            }
        }
    }

    private func arrivedHeader(_ a: Agent) -> some View {
        VStack(spacing: 10) {
            StareOrb(agent: a, size: 84)
                .padding(.top, 12)
            if state.activeId == a.id {
                PhaseLabel(phase: state.phase)
            } else if state.hasHeadData {
                Text(state.focusedId == a.id ? "Keep looking…" : "Turn toward \(a.name) to talk")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Button("Talk") { state.wake(a) }.buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 10)
    }
}
