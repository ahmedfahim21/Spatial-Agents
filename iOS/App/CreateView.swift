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
    enum Field: Hashable { case name, greeting, context }

    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// Called with the new agent once it's saved (Create is a sheet over Agents).
    var onCreated: ((Agent) -> Void)?
    @State private var name = ""
    @State private var color: BotColor = .cyan
    @State private var shape: BotShape = .circle
    @State private var voice = VoicePalette.voices[0].id
    @State private var greeting = ""
    @State private var context = ""
    @State private var radius = 25.0
    @State private var acceptsPayments = false
    @State private var catalog = [CatalogDraft()]
    @State private var template: AgentTemplate?
    @State private var model = ZGModel.defaultId
    @State private var privateInference = false
    @State private var tools = Set(AgentTool.available)
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
                } header: {
                    // In the header, not a row: rows clip to their rounded bounds, which sliced
                    // the cards. Here the row scrolls edge to edge.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Start from")
                        // Out to the screen edges; the cards line up with the form below.
                        TemplatePicker(selected: template, inset: 16) { apply($0) }
                            .padding(.horizontal, -32)
                    }
                    .textCase(nil)
                    .padding(.bottom, 14)
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
                    ModelRow(model: $model, privateOnly: privateInference)
                    PrivateInferenceRow(isOn: $privateInference, model: $model)
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

                if flavor != .publicPlace {
                    ToolAccessSection(selection: $tools)
                }

                // Its own view: it follows GPS, and the rest of the form shouldn't redraw with it.
                if flavor.needsPlace {
                    PlaceSection(radius: $radius, place: $place, color: color, shape: shape) {
                        field = nil
                        picking = true
                    }
                }

                if flavor == .publicPlace {
                    PaymentsSection(enabled: $acceptsPayments, items: $catalog)
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
            .navigationTitle("New agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
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

    // MARK: Templates

    /// Fills the form from a template. A name you typed yourself is kept.
    private func apply(_ t: AgentTemplate) {
        withAnimation(Motion.snappy) {
            if name.isEmpty || name == template?.name { name = t.name }
            template = t
            state.createFlavor = t.flavor
            greeting = t.greeting
            context = t.context
            color = t.color
            shape = t.shape
            voice = t.voice
            radius = t.radius
            if !t.menu.isEmpty {
                acceptsPayments = true
                catalog = t.menu.map { var d = CatalogDraft(); d.name = $0.0; d.price = $0.1; return d }
            }
        }
        state.haptics.tap(intensity: 0.5, sharpness: 0.5)
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
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving
            && (!state.createFlavor.needsPlace || place != nil || state.location.hasFix)
            && (!selling || (!menu.isEmpty && catalog.allSatisfy { $0.isValid || $0.isBlank }))
    }

    private var selling: Bool { state.createFlavor == .publicPlace && acceptsPayments }
    /// The rows filled in (blank rows are ignored).
    private var menu: [CatalogItem] { catalog.compactMap(\.item) }

    private func save() {
        let flavor = state.createFlavor
        let c = spot
        var new = NewAgent(
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
            radiusM: radius
        )
        if model != ZGModel.defaultId { new.model = model }
        if privateInference { new.privateInference = true }
        let items = selling ? menu : []
        field = nil
        saving = true
        withAnimation(Motion.snappy) { result = nil }
        Task {
            do {
                let a = try await state.create(new)
                if flavor != .publicPlace { ToolAccess.set(tools, for: a.id) }
                var done = flavor == .withMe ? "\(a.name) is with you now." : "\(a.name) is on the map."
                if !items.isEmpty {
                    do {
                        try await state.openShop(a, items: items)
                        done = "\(a.name) is on the map and taking payments."
                    } catch {
                        // The agent exists; only selling failed. Say so rather than hide it.
                        throw BackendError(message: "\(a.name) is on the map, but payments couldn't be turned on: \(error.localizedDescription)")
                    }
                }
                state.haptics.arrived()
                if let onCreated { onCreated(a); saving = false; return }
                withAnimation(Motion.snappy) { result = .success(done) }
                name = ""; greeting = ""; context = ""; place = nil
                acceptsPayments = false; catalog = [CatalogDraft()]
            } catch {
                withAnimation(Motion.snappy) { result = .failure(error) }
            }
            saving = false
        }
    }
}

/// Where a placed agent will live: a live preview, the arrival radius, and the map picker.
struct PlaceSection: View {
    @Environment(MobileState.self) private var state
    @Binding var radius: Double
    @Binding var place: CLLocationCoordinate2D?
    let color: BotColor
    let shape: BotShape
    let chooseOnMap: () -> Void

    var body: some View {
        Section {
            if let c = place ?? state.location.coordinate {
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
            Button(action: chooseOnMap) {
                Label("Choose on map", systemImage: "map")
            }
        } header: { Text("Place") } footer: {
            if place == nil, state.location.isPoorFix {
                Text("GPS is rough here. Choosing on the map is more precise.")
            }
        }
    }
}

/// The eight colours; a ring slides to the chosen one.
struct ColorRow: View {
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
struct ShapeRow: View {
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
