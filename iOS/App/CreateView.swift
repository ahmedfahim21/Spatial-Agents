import CoreLocation
import SwiftUI

/// What kind of agent you're making.
enum AgentFlavor: String, CaseIterable, Identifiable {
    case withMe = "With me"
    case privatePlace = "Private place"
    case publicPlace = "Public place"

    var id: String { rawValue }

    var detail: String {
        switch self {
        case .withMe: "Travels with you, sitting around your head. Only you hear it."
        case .privatePlace: "Lives at a place you choose. Only you can find it."
        case .publicPlace: "Lives at a place you choose. Anyone nearby can discover it and talk to it."
        }
    }

    var needsPlace: Bool { self != .withMe }
}

/// Make an agent: who it is, what it knows, and where it lives.
struct CreateView: View {
    enum Field: Hashable { case name, greeting, context, wallet }

    @Environment(MobileState.self) private var state
    @State private var name = ""
    @State private var color: BotColor = .cyan
    @State private var shape: BotShape = .circle
    @State private var voice = VoicePalette.voices[0].id
    @State private var greeting = ""
    @State private var context = ""
    @State private var radius = 25.0
    @State private var wallet = ""
    /// Where a placed agent goes; nil = wherever you are when you tap Create.
    @State private var place: CLLocationCoordinate2D?
    @State private var picking = false
    @State private var saving = false
    @State private var result: Result<String, Error>?
    @FocusState private var field: Field?

    private let nameLimit = 60

    var body: some View {
        @Bindable var state = state
        let flavor = state.createFlavor
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $state.createFlavor) {
                        ForEach(AgentFlavor.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(flavor.detail).contentTransition(.opacity).animation(Motion.snappy, value: flavor)
                }

                Section {
                    preview.listRowBackground(Color.clear)
                }

                Section {
                    HStack {
                        Text("Name")
                        TextField("Hack Help Desk", text: $name)
                            .focused($field, equals: .name)
                            .submitLabel(.next)
                            .onSubmit { field = .greeting }
                            .onChange(of: name) { _, v in if v.count > nameLimit { name = String(v.prefix(nameLimit)) } }
                        Text("\(nameLimit - name.count)").font(.subheadline).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    Picker("Voice", selection: $voice) {
                        ForEach(VoicePalette.voices, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Colour and shape") {
                    ColorRow(selection: $color)
                    ShapeRow(color: color, selection: $shape)
                }

                Section {
                    TextField("Hey, I'm the help desk. Ask me about Wi-Fi, mentors, food or the schedule.", text: $greeting, axis: .vertical)
                        .lineLimit(2...5)
                        .focused($field, equals: .greeting)
                        .submitLabel(.next)
                        // Multi-line fields swallow return; use it to move on instead.
                        .onChange(of: greeting) { _, v in
                            if v.contains("\n") { greeting = v.replacingOccurrences(of: "\n", with: ""); field = .context }
                        }
                } header: { Text("Greeting") } footer: { Text("The first thing it says when someone wakes it up.") }

                Section {
                    TextField("What it knows and how it behaves: schedule, Wi-Fi password, house rules, personality…", text: $context, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($field, equals: .context)
                } header: { Text("Context") } footer: { Text("Only you see this. People who talk to it never do.") }

                if flavor.needsPlace { placeSection }

                if flavor == .publicPlace {
                    Section {
                        TextField("Wallet address (optional)", text: $wallet)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($field, equals: .wallet)
                            .submitLabel(.done)
                            .onSubmit { field = nil }
                        LabeledContent("Price", value: "Free")
                    } header: { Text("Payments") } footer: { Text("Paid agents (x402) are coming soon.") }
                }

                Section {
                    VStack(spacing: 12) {
                        Button { save() } label: {
                            if saving { ProgressView().tint(Color(.systemBackground)) } else { Text("Create agent") }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!canSave)
                        if let result { resultView(result) }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .animation(Motion.snappy, value: flavor)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Create")
            .toolbar {
                if field != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { field = nil }.fontWeight(.semibold)
                    }
                }
            }
            .sheet(isPresented: $picking) {
                PlacePicker(start: spot, color: color, shape: shape) { place = $0 }
            }
        }
    }

    // MARK: Pieces

    private var preview: some View {
        VStack(spacing: 10) {
            BotView(color: color, shape: shape, mood: .arrived, size: 88, seed: 0.3)
                .keyframeAnimator(initialValue: 1.0, trigger: "\(color.rawValue)\(shape.rawValue)") { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    SpringKeyframe(1.08, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1, duration: 0.35, spring: .bouncy)
                }
            Text(name.isEmpty ? "Your agent" : name)
                .font(.title3.bold())
                .foregroundStyle(name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private var placeSection: some View {
        Section {
            if let c = spot {
                PlacePreview(coordinate: c, radius: radius, color: color, shape: shape)
                    .listRowInsets(EdgeInsets())
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Arrive within")
                    Spacer()
                    Text("\(Int(radius)) m").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $radius, in: 5...150, step: 5)
            }
            HStack {
                Text(place == nil ? "Pinned here" : "Chosen on the map")
                Spacer()
                if place != nil {
                    Button("Use my spot") { withAnimation(Motion.snappy) { place = nil } }
                        .buttonStyle(.borderless)
                } else if state.location.coordinate != nil {
                    Text("±\(Int(state.location.accuracy)) m").foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text("Finding you…").foregroundStyle(.secondary)
                }
            }
            Button { field = nil; picking = true } label: {
                Label("Choose on map", systemImage: "map")
            }
        } header: { Text("Place") } footer: {
            if place == nil, state.location.isPoorFix {
                Text("GPS is rough here. Choosing on the map is more precise.")
            }
        }
    }

    @ViewBuilder private func resultView(_ result: Result<String, Error>) -> some View {
        switch result {
        case .success(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .transition(.opacity)
        }
    }

    // MARK: Saving

    private var spot: CLLocationCoordinate2D? { place ?? state.location.coordinate }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving && (!state.createFlavor.needsPlace || spot != nil)
    }

    private func save() {
        let flavor = state.createFlavor
        let c = spot
        let new = NewAgent(
            kind: flavor == .publicPlace ? .public : .personal,
            anchor: flavor == .withMe ? .body : .geo,
            visibility: flavor == .publicPlace ? .public : .private,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            emoji: nil,
            color: color.hex,
            shape: shape.rawValue,
            voiceId: voice,
            greeting: greeting.trimmingCharacters(in: .whitespacesAndNewlines),
            context: context.trimmingCharacters(in: .whitespacesAndNewlines),
            lat: flavor.needsPlace ? c?.latitude : nil,
            lng: flavor.needsPlace ? c?.longitude : nil,
            radiusM: radius,
            walletAddress: wallet.isEmpty ? nil : wallet.trimmingCharacters(in: .whitespaces)
        )
        field = nil
        saving = true
        withAnimation(Motion.snappy) { result = nil }
        Task {
            do {
                let a = try await state.create(new)
                state.haptics.arrived()
                withAnimation(Motion.snappy) {
                    result = .success(flavor == .withMe ? "\(a.name) is with you now." : "\(a.name) is on the map.")
                }
                name = ""; greeting = ""; context = ""; wallet = ""; place = nil
            } catch {
                withAnimation(Motion.snappy) { result = .failure(error) }
            }
            saving = false
        }
    }
}

/// The eight colours; a ring slides to the chosen one.
private struct ColorRow: View {
    @Binding var selection: BotColor
    @Namespace private var ring

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BotColor.allCases) { c in
                Button {
                    withAnimation(Motion.snappy) { selection = c }
                } label: {
                    Circle().fill(c.color)
                        .frame(width: 30, height: 30)
                        .padding(4)
                        .background {
                            if selection == c {
                                Circle().stroke(Color.primary, lineWidth: 2).matchedGeometryEffect(id: "ring", in: ring)
                            }
                        }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(c.rawValue.capitalized)
                .accessibilityAddTraits(selection == c ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

/// The five shapes, drawn in the chosen colour; a soft tile slides to the chosen one.
private struct ShapeRow: View {
    let color: BotColor
    @Binding var selection: BotShape
    @Namespace private var tile

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BotShape.allCases) { s in
                Button {
                    withAnimation(Motion.snappy) { selection = s }
                } label: {
                    BotView(color: color, shape: s, size: 34)
                        .padding(9)
                        .background {
                            if selection == s {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(.systemGray5))
                                    .matchedGeometryEffect(id: "tile", in: tile)
                            }
                        }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(s.label)
                .accessibilityAddTraits(selection == s ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }
}
