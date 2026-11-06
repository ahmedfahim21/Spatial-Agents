
import CoreLocation
import MapKit
import SwiftUI

extension Agent {
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

/// Explore as a map: you, and every agent near you as a little bot with its reach.
struct ExploreMap: View {
    @Environment(MobileState.self) private var state
    @Binding var selected: UUID?
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $camera, selection: $selected) {
            if let sim = state.location.simulated {
                Annotation("You", coordinate: sim) { YouDot() }
            } else {
                UserAnnotation()
            }
            ForEach(state.nearby.filter { $0.coordinate != nil }) { a in
                MapCircle(center: a.coordinate!, radius: a.radiusM)
                    .foregroundStyle(a.tint.opacity(selected == a.id ? 0.22 : 0.14))
                    .stroke(a.tint.opacity(0.55), lineWidth: 1)
                // Annotation content is hosted outside this view tree on device, so it can't
                // read the environment: hand it everything it needs.
                Annotation(a.name, coordinate: a.coordinate!, anchor: .center) {
                    MapBot(agent: a, mood: state.mood(for: a), distance: state.distance(to: a), selected: selected == a.id)
                }
                .annotationTitles(.hidden)
                .tag(a.id)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        // Start at street level around you, once we know where you are.
        .onChange(of: state.location.coordinate == nil, initial: true) { _, unknown in
            guard !unknown, !framed, let here = state.location.coordinate else { return }
            framed = true
            camera = .region(MKCoordinateRegion(center: here, latitudinalMeters: 700, longitudinalMeters: 700))
        }
    }

    @State private var framed = false
}

/// An agent on the map: bigger when it's close, with its name when selected.
private struct MapBot: View {
    let agent: Agent
    let mood: BotMood
    let distance: Double?
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            if selected {
                Text(agent.name)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
            BotView(agent: agent, mood: mood, size: size)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
        }
        .animation(Motion.snappy, value: selected)
    }

    private var size: CGFloat {
        if selected { return 44 }
        guard let d = distance else { return 26 }
        switch d {
        case ..<60: return 34
        case ..<250: return 28
        case ..<800: return 24
        default: return 20
        }
    }
}

/// Your position in demo mode (the real one uses MapKit's own dot).
private struct YouDot: View {
    var body: some View {
        Circle().fill(Color.blue).frame(width: 16, height: 16)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.2), radius: 3)
    }
}

/// A small, non-interactive map showing where an agent will be and how far it reaches.
struct PlacePreview: View {
    let coordinate: CLLocationCoordinate2D
    let radius: Double
    let color: BotColor
    let shape: BotShape

    var body: some View {
        Map(position: .constant(.region(MKCoordinateRegion(center: coordinate,
                                                           latitudinalMeters: max(160, radius * 5),
                                                           longitudinalMeters: max(160, radius * 5)))),
            interactionModes: []) {
            MapCircle(center: coordinate, radius: radius)
                .foregroundStyle(color.color.opacity(0.2))
                .stroke(color.color, lineWidth: 1.5)
            Annotation("", coordinate: coordinate) {
                BotView(color: color, shape: shape, size: 30).shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 150)
        .allowsHitTesting(false)
    }
}

/// Pick where an agent lives: drag the map under the pin, or search for a place.
struct PlacePicker: View {
    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let start: CLLocationCoordinate2D?
    let color: BotColor
    let shape: BotShape
    let onPick: (CLLocationCoordinate2D) -> Void

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var moving = false
    @State private var query = ""
    @State private var results: [MKMapItem] = []

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera) {
                    UserAnnotation()
                    ForEach(state.nearby.filter { $0.coordinate != nil }) { a in
                        Annotation(a.name, coordinate: a.coordinate!) { BotView(agent: a, size: 22).opacity(0.7) }
                            .annotationTitles(.hidden)
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .mapControls { MapUserLocationButton(); MapCompass() }
                .onMapCameraChange(frequency: .continuous) { ctx in
                    center = ctx.region.center
                    if !moving { withAnimation(Motion.snappy) { moving = true } }
                }
                .onMapCameraChange(frequency: .onEnd) { _ in
                    withAnimation(Motion.lively) { moving = false }
                }

                // The agent stays in the middle; the map moves under it. It lifts while
                // the map moves and drops when it settles.
                VStack(spacing: 0) {
                    BotView(color: color, shape: shape, mood: moving ? .idle : .arrived, size: 44)
                        .shadow(color: .black.opacity(0.2), radius: moving ? 10 : 3, y: moving ? 8 : 2)
                        .offset(y: moving ? -14 : 0)
                    Ellipse().fill(.black.opacity(0.25)).frame(width: moving ? 10 : 16, height: 5)
                        .padding(.top, 2)
                }
                .offset(y: -22)
                .allowsHitTesting(false)

                if !results.isEmpty { resultsList }
            }
            .navigationTitle("Choose a place")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search a place or address")
            .onSubmit(of: .search, search)
            .onChange(of: query) { _, q in if q.isEmpty { results = [] } }
            .safeAreaInset(edge: .bottom) {
                Button("Place agent here") {
                    if let center { onPick(center) }
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(center == nil)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear {
                if let start {
                    camera = .region(MKCoordinateRegion(center: start, latitudinalMeters: 300, longitudinalMeters: 300))
                    center = start
                }
            }
        }
    }

    private var resultsList: some View {
        VStack {
            VStack(spacing: 0) {
                ForEach(Array(results.prefix(6).enumerated()), id: \.offset) { i, item in
                    if i > 0 { RowDivider() }
                    Button {
                        let c = item.location.coordinate
                        withAnimation(Motion.smooth) {
                            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 300, longitudinalMeters: 300))
                        }
                        results = []
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Place").foregroundStyle(.primary)
                            if let sub = item.address?.shortAddress {
                                Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .card()
            .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
            .padding(12)
            Spacer()
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        if let c = center ?? state.location.coordinate {
            req.region = MKCoordinateRegion(center: c, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        Task {
            let found = try? await MKLocalSearch(request: req).start()
            withAnimation(Motion.snappy) { results = found?.mapItems ?? [] }
        }
    }
}
