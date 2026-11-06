import SwiftUI

/// A chat model on the 0G Compute Router, which every agent thinks with.
struct ZGModel: Identifiable, Decodable, Hashable {
    let id: String
    let name: String?
    let description: String?
    let type: String?
    let teeAttested: Bool?
    /// "TeeML" when the model itself runs in an enclave, the only models the private tier serves.
    let verifiability: String?

    enum CodingKeys: String, CodingKey { case id, name, description, type, verifiability, teeAttested = "tee_attested" }

    /// The server's default (`ZG_MODEL`).
    static let defaultId = "claude-haiku-5.5"
    /// The server's default for private agents (`ZG_PRIVATE_MODEL`).
    static let privateDefaultId = "0gm-1.0-35b-a3b"

    /// Quick to answer, which matters when the reply is spoken. In this order.
    static let recommended: [(id: String, note: String)] = [
        (defaultId, "Fast and natural. The default."),
        ("claude-sonnet-5.5", "Smarter, a little slower."),
        ("0gm-1.0-35b-a3b", "0G's own model."),
        ("gpt-5.4-mini", "Fast, good all-rounder."),
        ("gemini-3.5-flash", "Fast, knows a lot."),
        ("deepseek-v4-flash", "Fast and inexpensive."),
        ("qwen3.7-flash", "Fast, multilingual."),
    ]

    /// Quick to answer among the private models. In this order.
    static let recommendedPrivate: [(id: String, note: String)] = [
        (privateDefaultId, "0G's own model. The private default."),
        ("glm-5.3", "Smarter, a little slower."),
    ]

    var displayName: String { name ?? id }
    var isPrivate: Bool { verifiability == "TeeML" }

    /// Grouped by maker in the full list.
    var family: String {
        let p = id.lowercased()
        for (prefix, family) in [("claude", "Claude"), ("gpt", "GPT"), ("gemini", "Gemini"), ("deepseek", "DeepSeek"),
                                 ("qwen", "Qwen"), ("glm", "GLM"), ("kimi", "Kimi"), ("minimax", "MiniMax"), ("0gm", "0G")]
            where p.hasPrefix(prefix) { return family }
        return "Other"
    }

    @MainActor static func displayName(_ id: String?) -> String {
        let id = id ?? defaultId
        return ModelCatalog.shared.models.first { $0.id == id }?.displayName ?? (id == defaultId ? "Claude Haiku 5.5" : id)
    }
}

/// The router's chat models, fetched once per launch (the list is public).
@MainActor @Observable
final class ModelCatalog {
    static let shared = ModelCatalog()
    private(set) var models: [ZGModel] = []
    private(set) var failed = false
    private var loading = false

    func load() async {
        guard models.isEmpty, !loading else { return }
        loading = true
        defer { loading = false }
        struct List: Decodable { let data: [ZGModel] }
        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://router-api.0g.ai/v1/models")!)
            models = try JSONDecoder().decode(List.self, from: data).data.filter { $0.type == "chatbot" }
            failed = false
        } catch {
            failed = true
        }
    }
}

/// "Model" row for Create and Edit: opens the picker.
struct ModelRow: View {
    @Binding var model: String
    var privateOnly = false

    var body: some View {
        NavigationLink {
            ModelPicker(selection: $model, privateOnly: privateOnly)
        } label: {
            HStack {
                Text("Model")
                Spacer()
                Text(ZGModel.displayName(model)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .task { await ModelCatalog.shared.load() }
    }
}

/// "Private inference" switch for Create and Edit. Turning it on moves the agent to a private
/// model, because the private tier can't serve the others.
struct PrivateInferenceRow: View {
    @Binding var isOn: Bool
    @Binding var model: String

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Private inference")
                Text("The model runs sealed in a TEE on 0G, with fewer models to choose from.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .onChange(of: isOn) { _, on in
            guard on, ModelCatalog.shared.models.first(where: { $0.id == model })?.isPrivate != true else { return }
            model = ZGModel.privateDefaultId
        }
    }
}

struct ModelPicker: View {
    @Binding var selection: String
    var privateOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var catalog: ModelCatalog { .shared }

    var body: some View {
        List {
            if available.isEmpty {
                Section {
                    if !catalog.models.isEmpty {
                        Label("0G has no private models right now.", systemImage: "lock.slash")
                            .foregroundStyle(.secondary)
                    } else if catalog.failed {
                        Label("Couldn't load 0G's models. Check your connection.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
            }
            if search.isEmpty, !recommended.isEmpty {
                Section {
                    ForEach(recommended, id: \.0.id) { m, note in row(m, note: note) }
                } header: { Text("Recommended for talking") } footer: {
                    Text(privateOnly
                        ? "Private inference shows only models that run sealed in a TEE. Turn it off for the full catalogue."
                        : "Every agent thinks through the 0G Compute Router. Models marked TEE run in attested hardware enclaves.")
                }
            }
            ForEach(families, id: \.0) { family, models in
                Section(family) {
                    ForEach(models) { row($0, note: nil) }
                }
            }
        }
        .searchable(text: $search, prompt: "Search 0G models")
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .task { await catalog.load() }
    }

    private var available: [ZGModel] { privateOnly ? catalog.models.filter(\.isPrivate) : catalog.models }

    private var recommended: [(ZGModel, String)] {
        (privateOnly ? ZGModel.recommendedPrivate : ZGModel.recommended)
            .compactMap { r in available.first { $0.id == r.id }.map { ($0, r.note) } }
    }

    private var families: [(String, [ZGModel])] {
        let q = search.lowercased()
        let shown = available.filter { q.isEmpty || $0.id.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
        let order = ["Claude", "GPT", "Gemini", "0G", "DeepSeek", "Qwen", "GLM", "Kimi", "MiniMax", "Other"]
        return Dictionary(grouping: shown, by: \.family)
            .map { ($0.key, $0.value.sorted { $0.id < $1.id }) }
            .sorted { (order.firstIndex(of: $0.0) ?? 99) < (order.firstIndex(of: $1.0) ?? 99) }
    }

    private func row(_ m: ZGModel, note: String?) -> some View {
        Button {
            selection = m.id
            dismiss()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(m.displayName).foregroundStyle(.primary)
                        if m.teeAttested == true {
                            Text("TEE").font(.caption2.weight(.bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color(.systemGray5), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let text = note ?? m.description {
                        Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if selection == m.id {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                }
            }
        }
    }
}
