import CoreLocation
import SwiftUI

/// Change one of your agents: who it is, what it knows, where it lives and, for public
/// places, what it sells. Whether it's "with me" or placed stays as it was made.
struct EditAgentView: View {
    @Environment(MobileState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let agent: Agent

    @State private var name: String
    @State private var color: BotColor
    @State private var shape: BotShape
    @State private var voice: String
    @State private var greeting: String
    @State private var context: String
    @State private var radius: Double
    @State private var model: String
    /// Where it lives; nil = move it to where you are now.
    @State private var place: CLLocationCoordinate2D?
    @State private var acceptsPayments: Bool
    @State private var catalog: [CatalogDraft] = [CatalogDraft()]
    @State private var menuLoaded = false
    @State private var picking = false
    @State private var saving = false
    @State private var problem: String?

    private let nameLimit = 60

    init(agent: Agent) {
        self.agent = agent
        _name = State(initialValue: agent.name)
        _color = State(initialValue: agent.botColor)
        _shape = State(initialValue: agent.botShape)
        _voice = State(initialValue: agent.voiceId ?? VoicePalette.voices[0].id)
        _greeting = State(initialValue: agent.greeting)
        _context = State(initialValue: agent.context ?? "")
        _radius = State(initialValue: agent.radiusM)
        _model = State(initialValue: agent.model ?? ZGModel.defaultId)
        _place = State(initialValue: agent.coordinate)
        _acceptsPayments = State(initialValue: agent.pricing == "paid")
    }

    private var sells: Bool { agent.isPublic && agent.isGeo }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Name")
                        TextField("Name", text: $name)
                            .onChange(of: name) { _, v in if v.count > nameLimit { name = String(v.prefix(nameLimit)) } }
                    }
                    Picker("Voice", selection: $voice) {
                        ForEach(VoicePalette.voices, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.navigationLink)
                    ModelRow(model: $model)
                }

                Section("Colour and shape") {
                    ColorRow(selection: $color)
                    ShapeRow(color: color, selection: $shape)
                }

                Section {
                    TextField("What it says when someone wakes it up", text: $greeting, axis: .vertical)
                        .lineLimit(2...5)
                } header: { Text("Greeting") }

                Section {
                    TextField("What it knows and how it behaves", text: $context, axis: .vertical)
                        .lineLimit(4...12)
                } header: { Text("Context") } footer: { Text("Only you see this. People who talk to it never do.") }

                if agent.isGeo {
                    PlaceSection(radius: $radius, place: $place, color: color, shape: shape) { picking = true }
                }

                if sells {
                    if menuLoaded {
                        PaymentsSection(enabled: $acceptsPayments, items: $catalog)
                    } else {
                        Section("Payments") { ProgressView().frame(maxWidth: .infinity) }
                    }
                }

                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit \(agent.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
            .sheet(isPresented: $picking) {
                PlacePicker(start: place ?? state.location.coordinate, color: color, shape: shape) { place = $0 }
            }
            .interactiveDismissDisabled(saving)
            .task { await loadMenu() }
        }
    }

    private var menu: [CatalogItem] { catalog.compactMap(\.item) }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving
            && (!agent.isGeo || place != nil || state.location.hasFix)
            && (!sells || !acceptsPayments || (menuLoaded && !menu.isEmpty && catalog.allSatisfy { $0.isValid || $0.isBlank }))
    }

    private func loadMenu() async {
        guard sells, !menuLoaded else { return }
        if agent.pricing == "paid", let items = try? await Backend.shared.catalog(agentId: agent.id), !items.isEmpty {
            catalog = items.map(CatalogDraft.init)
        }
        menuLoaded = true
    }

    private func save() {
        let spot = place ?? state.location.coordinate
        let changes = Backend.AgentChanges(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color.hex,
            shape: shape.rawValue,
            voiceId: voice,
            greeting: greeting.trimmingCharacters(in: .whitespacesAndNewlines),
            context: context.trimmingCharacters(in: .whitespacesAndNewlines),
            lat: agent.isGeo ? spot?.latitude : nil,
            lng: agent.isGeo ? spot?.longitude : nil,
            radiusM: radius,
            model: model != (agent.model ?? ZGModel.defaultId) ? model : nil
        )
        // Payments: the menu as edited, empty to stop selling, or untouched if not loaded.
        let newMenu: [CatalogItem]? = sells && menuLoaded ? (acceptsPayments ? menu : []) : nil
        saving = true
        problem = nil
        Task {
            do {
                try await state.update(agent.id, changes, menu: newMenu)
                state.haptics.arrived()
                dismiss()
            } catch {
                withAnimation(Motion.snappy) { problem = error.localizedDescription }
            }
            saving = false
        }
    }
}
