import CoreLocation
import SwiftUI

/// Make a personal agent (with you, or left at a place) or a public agent at a place.
struct CreateView: View {
    enum Flavor: String, CaseIterable, Identifiable {
        case withMe = "With me"
        case leaveHere = "Private place"
        case publicHere = "Public place"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .withMe: return "A private agent that travels with you, sitting around your head."
            case .leaveHere: return "A private agent pinned to a place. Only you can find it."
            case .publicHere: return "Pinned to a place. Anyone nearby can discover it and talk to it."
            }
        }
    }

    @EnvironmentObject var state: MobileState
    @State private var flavor: Flavor = .publicHere
    @State private var name = ""
    @State private var emoji = ""
    @State private var color = Color.agentPalette[0]
    @State private var voice = VoicePalette.voices[0].id
    @State private var greeting = ""
    @State private var context = ""
    @State private var radius = 25.0
    @State private var wallet = ""
    @State private var saving = false
    @State private var message: String?
    /// Where a placed agent goes; nil = wherever you are when you tap Create.
    @State private var place: CLLocationCoordinate2D?
    @State private var picking = false
    enum Field: Hashable { case name, emoji, greeting, context, wallet }
    @FocusState private var field: Field?

    private var needsLocation: Bool { flavor != .withMe }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving && (!needsLocation || spot != nil)
    }
    private var spot: CLLocationCoordinate2D? { place ?? state.location.coordinate
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $flavor) { ForEach(Flavor.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                    Text(flavor.detail).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Identity") {
                    TextField("Name", text: $name)
                        .focused($field, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { field = .emoji }
                    TextField("Emoji (optional)", text: $emoji)
                        .focused($field, equals: .emoji)
                        .submitLabel(.next)
                        .onSubmit { field = .greeting }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(Color.agentPalette, id: \.self) { hex in
                                Circle().fill(Color(hex: hex)!).frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(.white, lineWidth: color == hex ? 3 : 0))
                                    .onTapGesture { color = hex }
                            }
                        }
                    }
                    Picker("Voice", selection: $voice) {
                        ForEach(VoicePalette.voices, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    TextField("Greeting, e.g. “Hey! I'm the help desk. Ask me anything about the venue.”", text: $greeting, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($field, equals: .greeting)
                        .submitLabel(.next)
                        // Multi-line fields swallow return; treat it as "next field" instead.
                        .onChange(of: greeting) { _, v in
                            if v.contains("\n") { greeting = v.replacingOccurrences(of: "\n", with: ""); field = .context }
                        }
                } header: { Text("Boot prompt") } footer: { Text("The first thing it says when someone wakes it up.") }
                Section {
                    TextField("What it knows and how it behaves: schedule, wifi password, sponsor booths, house rules, personality…", text: $context, axis: .vertical)
                        .lineLimit(5...12)
                        .focused($field, equals: .context)
                } header: { Text("Context") }
                if needsLocation {
                    Section {
                        if let c = spot {
                            PlacePreview(coordinate: c, radius: radius, tint: Color(hex: color) ?? .cyan)
                                .listRowInsets(EdgeInsets())
                        }
                        HStack {
                            Label(place == nil ? "Where you are now" : "Chosen on the map",
                                  systemImage: place == nil ? "location.fill" : "mappin.and.ellipse")
                                .font(.subheadline)
                            Spacer()
                            if place != nil {
                                Button("Use my spot") { place = nil }.font(.subheadline).buttonStyle(.borderless)
                            }
                        }
                        Button { field = nil; picking = true } label: {
                            Label("Choose on map", systemImage: "map")
                        }
                        Slider(value: $radius, in: 5...150, step: 5) { Text("Radius") }
                        Text("People arrive within \(Int(radius)) m").font(.footnote).foregroundStyle(.secondary)
                        if spot == nil {
                            Text("Waiting for your location… or choose a place on the map.").font(.footnote).foregroundStyle(.orange)
                        } else if place == nil, state.location.isPoorFix {
                            Text("GPS is rough here (±\(Int(state.location.accuracy)) m). Choosing on the map is more precise.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text("Place") }
                }
                if flavor == .publicHere {
                    Section {
                        TextField("Wallet address (optional)", text: $wallet)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($field, equals: .wallet)
                            .submitLabel(.done)
                            .onSubmit { field = nil }
                        LabeledContent("Price", value: "Free")
                    } header: { Text("Payments") } footer: { Text("Paid agents (x402) are coming soon.") }
                }
                Section {
                    Button(action: save) {
                        HStack { Spacer(); if saving { ProgressView() } else { Text("Create agent").bold() }; Spacer() }
                    }
                    .disabled(!canSave)
                    if let message { Text(message).font(.footnote).foregroundStyle(message.hasPrefix("Created") ? .green : .red) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if field != nil { KeyboardDoneBar { field = nil } }
            }
            .navigationTitle("Create")
            .sheet(isPresented: $picking) {
                PlacePicker(start: spot, radius: radius, tint: Color(hex: color) ?? .cyan) { place = $0 }
                    .environmentObject(state).environmentObject(state.head)
            }
        }
    }

    private func save() {
        let c = spot
        let new = NewAgent(
            kind: flavor == .publicHere ? .public : .personal,
            anchor: flavor == .withMe ? .body : .geo,
            visibility: flavor == .publicHere ? .public : .private,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: emoji.isEmpty ? nil : String(emoji.prefix(2)),
            color: color,
            voiceId: voice,
            greeting: greeting.trimmingCharacters(in: .whitespacesAndNewlines),
            context: context.trimmingCharacters(in: .whitespacesAndNewlines),
            lat: needsLocation ? c?.latitude : nil,
            lng: needsLocation ? c?.longitude : nil,
            radiusM: radius,
            walletAddress: wallet.isEmpty ? nil : wallet.trimmingCharacters(in: .whitespaces)
        )
        field = nil
        saving = true
        message = nil
        Task {
            do {
                let a = try await state.create(new)
                message = "Created \(a.name)" + (flavor == .withMe ? ". It's in “With me”." : ". It's on the map in Explore.")
                name = ""; emoji = ""; greeting = ""; context = ""; wallet = ""; place = nil
            } catch {
                message = error.localizedDescription
            }
            saving = false
        }
    }
}
