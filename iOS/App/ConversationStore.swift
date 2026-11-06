import Foundation

/// Keeps each agent's conversation on the phone, so coming back to an agent (even after
/// the app restarts) picks up where you left off. One JSON file in Application Support.
enum ConversationStore {
    /// Plenty to pick up from, without the file (or the prompt) growing forever.
    static let keepPerAgent = 80

    private struct Message: Codable {
        let id: UUID
        let kind: String   // "user" | "agent" | "order"
        let text: String
        let date: Date
    }

    private struct File: Codable {
        var conversations: [String: [Message]]
        var orders: [String: OrderCard]
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }

    static func load() -> (conversations: [UUID: [ChatMessage]], orders: [UUID: OrderCard]) {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return ([:], [:]) }
        var conversations: [UUID: [ChatMessage]] = [:]
        for (key, messages) in file.conversations {
            guard let id = UUID(uuidString: key) else { continue }
            conversations[id] = messages.compactMap { m in
                switch m.kind {
                case "user": ChatMessage(id: m.id, .user, m.text, date: m.date)
                case "agent": ChatMessage(id: m.id, .agent, m.text, date: m.date)
                case "order": ChatMessage(id: m.id, .order, m.text, date: m.date)
                default: nil
                }
            }
        }
        var orders: [UUID: OrderCard] = [:]
        for (key, card) in file.orders {
            guard let id = UUID(uuidString: key) else { continue }
            var card = card
            // An approval that was open when the app closed can be asked for again.
            if card.status == .approving { card.status = .needsApproval }
            orders[id] = card
        }
        return (conversations, orders)
    }

    static func save(_ conversations: [UUID: [ChatMessage]], orders: [UUID: OrderCard]) {
        var file = File(conversations: [:], orders: [:])
        var kept = Set<UUID>()
        for (id, messages) in conversations {
            let stored: [Message] = messages.suffix(keepPerAgent).compactMap { m in
                let kind: String
                switch m.kind {
                case .user: kind = "user"
                case .agent where !m.text.isEmpty: kind = "agent"
                case .order: kind = "order"
                default: return nil
                }
                if kind == "order" { kept.insert(m.id) }
                return Message(id: m.id, kind: kind, text: m.text, date: m.date)
            }
            if !stored.isEmpty { file.conversations[id.uuidString] = stored }
        }
        for (id, card) in orders where kept.contains(id) { file.orders[id.uuidString] = card }
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
