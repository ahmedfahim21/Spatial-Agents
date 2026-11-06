import SwiftUI

/// A chat model on the 0G Compute Router, which every agent thinks with.
struct ZGModel: Identifiable, Decodable, Hashable {
    let id: String
    let name: String?
    let description: String?
    let type: String?
    let teeAttested: Bool?

    enum CodingKeys: String, CodingKey { case id, name, description, type, teeAttested = "tee_attested" }

    /// The server's default (`ZG_MODEL`).
    static let defaultId = "claude-haiku-5.5"

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

    var displayName: String { name ?? id }

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

    var body: some View {
        NavigationLink {
            ModelPicker(selection: $model)
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

struct ModelPicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var catalog: ModelCatalog { .shared }

    var body: some View {
        List {
            if catalog.models.isEmpty {
                Section {
                    if catalog.failed {
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
                    Text("Every agent thinks through the 0G Compute Router. Models marked TEE run in attested hardware enclaves.")
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

    private var recommended: [(ZGModel, String)] {
        ZGModel.recommended.compactMap { r in catalog.models.first { $0.id == r.id }.map { ($0, r.note) } }
    }

    private var families: [(String, [ZGModel])] {
        let q = search.lowercased()
        let shown = catalog.models.filter { q.isEmpty || $0.id.lowercased().contains(q) || $0.displayName.lowercased().contains(q) }
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
