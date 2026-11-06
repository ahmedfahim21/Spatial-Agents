
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
            // Your dot, with a cone for where you're facing. The dot reads the direction itself,
            // so turning only re-renders the dot, never this map.
            if let sim = state.location.simulated {
                Annotation("You", coordinate: sim, anchor: .center) { YouDot(state: state, map: mapRotation) }
                    .annotationTitles(.hidden)
            } else {
                UserAnnotation(anchor: .center) { _ in YouDot(state: state, map: mapRotation) }
            }
            ForEach(state.nearby.filter { $0.coordinate != nil }) { a in
                MapCircle(center: a.coordinate!, radius: a.radiusM)
                    .foregroundStyle(a.tint.opacity(selected == a.id ? 0.22 : 0.14))
                    .stroke(a.tint.opacity(0.55), lineWidth: 1)
                // Annotation content is hosted outside this view tree on device, so it can't
                // read the environment: hand it everything it needs. Every change makes MapKit
                // re-measure the marker, so faces stay still here (no blinking at 30 fps) and
                // distance arrives as a size step, not a value that changes with every GPS fix.
                Annotation(a.name, coordinate: a.coordinate!, anchor: .center) {
                    MapBot(agent: a, mood: still(state.mood(for: a)),
                           size: MapBot.size(distance: state.distance(to: a), selected: selected == a.id),
                           selected: selected == a.id)
                        .equatable()
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
        .onMapCameraChange(frequency: .continuous) { ctx in
            mapRotation.degrees = ctx.camera.heading
        }
        // Start at street level around you, once we know where you are.
        .onChange(of: state.location.hasFix, initial: true) { _, hasFix in
            guard hasFix, !framed, let here = state.location.coordinate else { return }
            framed = true
            camera = .region(MKCoordinateRegion(center: here, latitudinalMeters: 700, longitudinalMeters: 700))
        }
    }

    @State private var framed = false
    /// The map's rotation. Only the dot reads it.
    @State private var mapRotation = MapRotation()

    /// The still version of a mood, for the map.
    private func still(_ mood: BotMood) -> BotMood {
        switch mood {
        case .error, .ended, .far: mood
        default: .idle
        }
    }
}

/// An agent on the map: bigger when it's close, with its name when selected.
private struct MapBot: View, Equatable {
    let agent: Agent
    let mood: BotMood
    let size: CGFloat
    let selected: Bool

    static func == (a: MapBot, b: MapBot) -> Bool {
        a.agent.id == b.agent.id && a.agent.name == b.agent.name && a.agent.color == b.agent.color
            && a.mood == b.mood && a.size == b.size && a.selected == b.selected
    }

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

    static func size(distance: Double?, selected: Bool) -> CGFloat {
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
/// The map camera's heading, shared with the dot without redrawing the map.
@Observable final class MapRotation {
    var degrees: Double = 0
}

/// You on the map: a blue dot, and a soft cone toward where you're facing: your head when
/// AirPods are tracking, otherwise the phone. Only the cone's rotation changes as you turn
/// (fixed size, so MapKit never re-measures it), animated between readings so it glides.
private struct YouDot: View {
    // Passed in, not from the environment: annotation content lives outside the view tree.
    let state: MobileState
    let map: MapRotation
    /// The cone's angle, unwrapped (it can pass 360) so crossing north turns the short way.
    @State private var shown: Double?

    /// Degrees clockwise from the top of the screen; nil = unknown (no cone).
    private var facing: Double? {
        (state.headWorld ?? state.location.heading).map { normalize360($0 - map.degrees) }
    }

    var body: some View {
        ZStack {
            if let shown {
                Cone()
                    .fill(RadialGradient(colors: [Color.blue.opacity(0.45), Color.blue.opacity(0)],
                                         center: .center, startRadius: 6, endRadius: 46))
                    .rotationEffect(.degrees(shown))
                    .transition(.opacity)
            }
            Circle().fill(Color.blue).frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.2), radius: 3)
        }
        .frame(width: 96, height: 96)
        .allowsHitTesting(false)
        .onChange(of: facing, initial: true) { _, target in
            guard let target else { withAnimation(.easeOut(duration: 0.2)) { shown = nil }; return }
            guard let from = shown else { shown = target; return }
            // Shortest way round: -180...180 from where it is now.
            let delta = (target - normalize360(from) + 540).truncatingRemainder(dividingBy: 360) - 180
            withAnimation(.linear(duration: 0.12)) { shown = from + delta }
        }
    }

    /// A 70° wedge from the centre, pointing up.
    private struct Cone: Shape {
        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            var p = Path()
            p.move(to: c)
            p.addArc(center: c, radius: rect.width / 2, startAngle: .degrees(-90 - 35), endAngle: .degrees(-90 + 35), clockwise: false)
            p.closeSubpath()
            return p
        }
    }
}

/// A small, non-interactive map showing where an agent will be and how far it reaches.
/// GPS wobbles by a metre or two every second; the map only follows real moves.
struct PlacePreview: View {
    let coordinate: CLLocationCoordinate2D
    let radius: Double
    let color: BotColor
    let shape: BotShape

    @State private var shown: CLLocationCoordinate2D?
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        let c = shown ?? coordinate
        Map(position: $camera, interactionModes: []) {
            MapCircle(center: c, radius: radius)
                .foregroundStyle(color.color.opacity(0.2))
                .stroke(color.color, lineWidth: 1.5)
            Annotation("", coordinate: c) {
                BotView(color: color, shape: shape, size: 30).shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 150)
        .allowsHitTesting(false)
        .onAppear { follow(coordinate, animated: false) }
        .onChange(of: GeoMath.distance(shown ?? coordinate, coordinate) > 4) { _, moved in
            if moved { follow(coordinate, animated: true) }
        }
        .onChange(of: radius) { _, _ in frame(animated: true) }
    }

    private func follow(_ c: CLLocationCoordinate2D, animated: Bool) {
        shown = c
        frame(animated: animated)
    }

    private func frame(animated: Bool) {
        let span = max(160, radius * 5)
        let region = MapCameraPosition.region(MKCoordinateRegion(center: shown ?? coordinate,
                                                                 latitudinalMeters: span, longitudinalMeters: span))
        if animated { withAnimation(Motion.smooth) { camera = region } } else { camera = region }
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
