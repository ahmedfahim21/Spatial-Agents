import CoreLocation
import MapKit
import SwiftUI

extension Agent {
    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }
}

/// An agent as an object on the map: its orb (glowing when you're facing it), name and distance.
struct AgentMapMarker: View {
    @EnvironmentObject var state: MobileState
    let agent: Agent

    var body: some View {
        VStack(spacing: 4) {
            StareOrb(agent: agent, size: state.arrived.contains(agent.id) ? 50 : 40)
                .shadow(color: agent.tint.opacity(0.6), radius: 8)
            HStack(spacing: 4) {
                Text(agent.name).font(.caption2.weight(.semibold)).lineLimit(1)
                if let d = state.distance(to: agent) {
                    Text(GeoMath.describe(distance: d)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if agent.isMine == true && !agent.isPublic {
                    Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.purple)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Explore as a map: you, and every agent near you as an object with its reach.
struct ExploreMap: View {
    @EnvironmentObject var state: MobileState
    @ObservedObject var location: LocationService
    let onSelect: (UUID) -> Void
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $camera) {
            if let sim = location.simulated {
                Annotation("You (demo)", coordinate: sim) {
                    Circle().fill(.purple).frame(width: 16, height: 16).overlay(Circle().stroke(.white, lineWidth: 3))
                }
            } else {
                UserAnnotation()
            }
            ForEach(state.nearby.filter { $0.coordinate != nil }) { a in
                MapCircle(center: a.coordinate!, radius: a.radiusM)
                    .foregroundStyle(a.tint.opacity(state.arrived.contains(a.id) ? 0.25 : 0.12))
                    .stroke(a.tint.opacity(0.5), lineWidth: 1)
                Annotation(a.name, coordinate: a.coordinate!, anchor: .center) {
                    AgentMapMarker(agent: a).onTapGesture { onSelect(a.id) }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapPitchToggle()
        }
        .onAppear {
            if let sim = location.simulated {
                camera = .region(MKCoordinateRegion(center: sim, latitudinalMeters: 400, longitudinalMeters: 400))
            }
        }
    }
}

/// A small, non-interactive map showing where an agent will be and how far it reaches.
struct PlacePreview: View {
    let coordinate: CLLocationCoordinate2D
    let radius: Double
    let tint: Color

    var body: some View {
        Map(position: .constant(.region(MKCoordinateRegion(center: coordinate,
                                                           latitudinalMeters: max(160, radius * 5),
                                                           longitudinalMeters: max(160, radius * 5)))),
            interactionModes: []) {
            MapCircle(center: coordinate, radius: radius).foregroundStyle(tint.opacity(0.2)).stroke(tint, lineWidth: 1.5)
            Annotation("", coordinate: coordinate) {
                Image(systemName: "mappin.circle.fill").font(.title).foregroundStyle(.white, tint)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }
}

/// Pick where an agent lives: drag the map under the pin, or search for a place.
struct PlacePicker: View {
    @EnvironmentObject var state: MobileState
    @Environment(\.dismiss) private var dismiss
    let start: CLLocationCoordinate2D?
    let radius: Double
    let tint: Color
    let onPick: (CLLocationCoordinate2D) -> Void

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var center: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false

    var body: some View {
        NavigationStack {
            ZStack {
                Map(position: $camera) {
                    UserAnnotation()
                    ForEach(state.nearby.filter { $0.coordinate != nil }) { a in
                        Annotation(a.name, coordinate: a.coordinate!) { AgentOrb(agent: a, size: 26).opacity(0.8) }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls { MapUserLocationButton(); MapCompass() }
                .onMapCameraChange(frequency: .continuous) { ctx in center = ctx.region.center }

                // The pin stays in the middle; the map moves under it.
                VStack(spacing: 0) {
                    ZStack {
                        Circle().fill(tint.opacity(0.18)).frame(width: 90, height: 90)
                        Image(systemName: "mappin.circle.fill").font(.system(size: 40)).foregroundStyle(.white, tint)
                            .shadow(radius: 4)
                    }
                    Text("Agent goes here").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3).background(.ultraThinMaterial, in: Capsule())
                }
                .allowsHitTesting(false)

                if !results.isEmpty {
                    VStack {
                        List(results, id: \.self) { item in
                            Button {
                                do {
                                    let c = item.location.coordinate
                                    withAnimation { camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: 300, longitudinalMeters: 300)) }
                                }
                                results = []
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "Place").font(.body)
                                    if let sub = item.address?.shortAddress { Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding()
                        Spacer()
                    }
                }
            }
            .navigationTitle("Choose a place")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search a place or address")
            .onSubmit(of: .search, search)
            .safeAreaInset(edge: .bottom) {
                Button {
                    if let center { onPick(center) }
                    dismiss()
                } label: {
                    Text("Place agent here").bold().frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(center == nil)
                .padding()
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
            results = Array(found?.mapItems.prefix(8) ?? [])
        }
    }
}
