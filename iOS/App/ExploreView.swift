import CoreLocation
import MapKit
import SwiftUI

/// Agents placed in the world near you, as a list or on a map.
struct ExploreView: View {
    enum Mode: String { case list, map }

    @Environment(MobileState.self) private var state
    @AppStorage("exploreMode") private var mode: Mode = .list
    @State private var selected: UUID?
    @State private var finding: FindTarget?

    var body: some View {
        Group {
            switch mode {
            case .list: list.transition(.opacity)
            case .map: map.transition(.opacity)
            }
        }
        .animation(Motion.snappy, value: mode)
        .fullScreenCover(item: $finding) { FindView(agentId: $0.id) }
        .task {
            #if DEBUG
            if let id = state.sampleFindTarget, ["find", "arrived"].contains(state.sampleScene) { finding = FindTarget(id: id) }
            #endif
            await state.refreshNearby(force: true)
        }
    }

    private var sorted: [Agent] {
        state.nearby.sorted { (state.distance(to: $0) ?? .infinity) < (state.distance(to: $1) ?? .infinity) }
    }

    private func open(_ a: Agent) { finding = FindTarget(id: a.id) }

    private var header: some View {
        HStack(alignment: .center) {
            ScreenTitle("Explore")
            ModeToggle(mode: $mode)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Notices().padding(.horizontal, 16)
                if sorted.isEmpty {
                    if state.location.coordinate != nil, !state.loading { EmptyExplore() }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Nearby").font(.title3.bold()).padding(.horizontal, 16)
                        VStack(spacing: 0) {
                            ForEach(Array(sorted.enumerated()), id: \.element.id) { i, a in
                                if i > 0 { RowDivider(leading: 76) }
                                Button { open(a) } label: { NearbyRow(agent: a) }
                                    .buttonStyle(PressableStyle())
                            }
                        }
                        .card()
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 24)
            .animation(Motion.snappy, value: sorted.map(\.id))
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await state.refreshNearby(force: true) }
    }

    // MARK: Map

    private var map: some View {
        ExploreMap(selected: $selected)
            .safeAreaInset(edge: .top, spacing: 0) {
                header
                    .padding(.bottom, 16)
                    .background(
                        LinearGradient(colors: [Color(.systemBackground).opacity(0.9), Color(.systemBackground).opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .top)
                    )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let a = state.agent(selected) {
                    SelectedCard(agent: a) { open(a) }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.smooth, value: selected)
    }
}

struct FindTarget: Identifiable { let id: UUID }

/// List / map switch: a white pill slides between the two icons.
private struct ModeToggle: View {
    @Binding var mode: ExploreView.Mode
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            option(.list, "list.bullet")
            option(.map, "map")
        }
        .padding(3)
        .background(Color(.systemGray5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func option(_ m: ExploreView.Mode, _ icon: String) -> some View {
        Button {
            withAnimation(Motion.snappy) { mode = m }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(mode == m ? .primary : .secondary)
                .frame(width: 44, height: 32)
                .background {
                    if mode == m {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(m == .list ? "List" : "Map")
    }
}

private struct NearbyRow: View {
    @Environment(MobileState.self) private var state
    let agent: Agent

    var body: some View {
        let here = state.arrived.contains(agent.id)
        HStack(spacing: 14) {
            BotView(agent: agent, mood: here ? state.mood(for: agent) : .idle, size: 44, look: here ? state.look(for: agent) : 0)
            VStack(alignment: .leading, spacing: 2) {
                AgentTitle(agent: agent, font: .body.weight(.semibold), badgeSize: 13, tappable: false).foregroundStyle(.primary)
                subtitle
            }
            Spacer(minLength: 8)
            if here {
                Text("Here").font(.body.weight(.semibold)).foregroundStyle(.primary)
            } else if let d = state.distance(to: agent) {
                HStack(spacing: 6) {
                    Text(state.distanceText(d)).monospacedDigit()
                    if let rot = state.screenArrow(to: agent) ?? state.bearing(to: agent) {
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 11))
                            .rotationEffect(.degrees(rot))
                            .animation(Motion.smooth, value: rot)
                    }
                }
                .font(.body)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var subtitle: some View {
        if agent.isMine == true && !agent.isPublic {
            Label("Only you", systemImage: "lock.fill")
                .labelStyle(TightLabel())
                .font(.subheadline).foregroundStyle(.secondary)
        } else if agent.pricing == "paid" {
            Label("Shop", systemImage: "bag.fill")
                .labelStyle(TightLabel())
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            Text("Free").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.caption2)
            configuration.title
        }
    }
}

/// Location, GPS and backend notices, in the design's quiet grey card.
private struct Notices: View {
    @Environment(MobileState.self) private var state

    var body: some View {
        let loc = state.location
        VStack(spacing: 8) {
            if !Config.isConfigured {
                notice("server.rack", "Connect the backend in Config.swift to see agents.")
            } else if loc.authorization == .denied || loc.authorization == .restricted {
                notice("location.slash", "Location is off. Allow it in Settings to find agents near you.")
            } else if loc.coordinate == nil {
                notice("location", "Finding your location…")
            }
            if !state.backendStatus.isEmpty {
                notice("exclamationmark.triangle", state.backendStatus)
            }
            if loc.simulated != nil {
                notice("theatermasks", "Demo mode: your location is simulated.")
            } else if loc.isPoorFix, loc.coordinate != nil {
                notice("info.circle", "GPS is rough indoors (±\(Int(loc.accuracy)) m), so arrival is more forgiving.")
            }
        }
    }

    private func notice(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.body)
            Text(text).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.secondary)
        .padding(14)
        .card()
    }
}

private struct EmptyExplore: View {
    @Environment(MobileState.self) private var state

    var body: some View {
        VStack(spacing: 14) {
            BotView(color: .violet, shape: .squircle, mood: .far, size: 64)
            Text("No agents here yet").font(.title3.bold())
            Text("Leave one here for others to find, or try somewhere busier.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Create an agent") {
                state.startCreating(.publicPlace)
            }
            .buttonStyle(SecondaryButtonStyle(fullWidth: false))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 48)
    }
}

/// The agent you tapped on the map: who, how far, and Find.
private struct SelectedCard: View {
    @Environment(MobileState.self) private var state
    let agent: Agent
    let find: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                BotView(agent: agent, mood: state.mood(for: agent), size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    AgentTitle(agent: agent)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Button(state.arrived.contains(agent.id) ? "Talk" : "Find", action: find)
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
    }

    private var detail: String {
        var parts: [String] = []
        if state.arrived.contains(agent.id) {
            parts.append("You're here")
        } else if let d = state.distance(to: agent) {
            let text = state.distanceText(d)
            parts.append(text == "Nearby" ? text : text + (state.bearing(to: agent).map { " " + Words.compass($0) } ?? ""))
        }
        parts.append(agent.isMine == true && !agent.isPublic ? "Only you" : agent.pricing == "paid" ? "Paid" : "Free")
        return parts.joined(separator: " · ")
    }
}
