import SwiftUI

/// Make a personal agent (with you, or left at this spot) or a public agent at this spot.
struct CreateView: View {
    enum Flavor: String, CaseIterable, Identifiable {
        case withMe = "With me"
        case leaveHere = "Leave it here"
        case publicHere = "Public, here"
        var id: String { rawValue }
        var detail: String {
            switch self {
            case .withMe: return "A private agent that travels with you, sitting around your head."
            case .leaveHere: return "A private agent pinned to this spot. Only you can find it."
            case .publicHere: return "Anyone nearby can discover it and talk to it."
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

    private var needsLocation: Bool { flavor != .withMe }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving && (!needsLocation || state.location.coordinate != nil)
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
                    TextField("Emoji (optional)", text: $emoji)
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
                } header: { Text("Boot prompt") } footer: { Text("The first thing it says when someone wakes it up.") }
                Section {
                    TextField("What it knows and how it behaves: schedule, wifi password, sponsor booths, house rules, personality…", text: $context, axis: .vertical)
                        .lineLimit(5...12)
                } header: { Text("Context") }
                if needsLocation {
                    Section {
                        Slider(value: $radius, in: 5...150, step: 5) { Text("Radius") }
                        Text("People arrive within \(Int(radius)) m").font(.footnote).foregroundStyle(.secondary)
                        if let c = state.location.coordinate {
                            Text(String(format: "Pinned at %.5f, %.5f (±%.0f m)", c.latitude, c.longitude, state.location.accuracy))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            Text("Waiting for your location…").font(.footnote).foregroundStyle(.orange)
                        }
                    } header: { Text("Place") }
                }
                if flavor == .publicHere {
                    Section {
                        TextField("Wallet address (optional)", text: $wallet)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
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
            .navigationTitle("Create")
        }
    }

    private func save() {
        let c = state.location.coordinate
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
        saving = true
        message = nil
        Task {
            do {
                let a = try await state.create(new)
                message = "Created \(a.name)" + (flavor == .withMe ? ". It's in “With me”." : ". It's on the map in Explore.")
                name = ""; emoji = ""; greeting = ""; context = ""; wallet = ""
            } catch {
                message = error.localizedDescription
            }
            saving = false
        }
    }
}
