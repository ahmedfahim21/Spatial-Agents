import Foundation

/// Loads the recent conversation of an existing Claude Code session from its transcript,
/// so attaching a session shows what was already said.
enum ChatHistory {
    static func load(sessionId: String, limit: Int = 40) -> [ChatMessage] {
        guard let url = transcriptURL(sessionId: sessionId),
              let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 1024 * 1024
        try? h.seek(toOffset: size > chunk ? size - chunk : 0)
        let data = (try? h.readToEnd()) ?? Data()

        var out: [ChatMessage] = []
        for raw in data.split(separator: UInt8(ascii: "\n")) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                  obj["isSidechain"] as? Bool != true, obj["isMeta"] as? Bool != true,
                  let msg = obj["message"] as? [String: Any] else { continue }
            let date = (obj["timestamp"] as? String).flatMap { ISO8601DateFormatter.withFractions.date(from: $0) } ?? Date()
            switch obj["type"] as? String {
            case "user":
                // Plain prompts only; skip tool results and local-command noise.
                if let text = msg["content"] as? String, isHumanText(text) {
                    out.append(ChatMessage(.user, text, date: date))
                } else if let blocks = msg["content"] as? [[String: Any]] {
                    for b in blocks where b["type"] as? String == "text" {
                        if let t = b["text"] as? String, isHumanText(t) { out.append(ChatMessage(.user, t, date: date)) }
                    }
                }
            case "assistant":
                for b in (msg["content"] as? [[String: Any]]) ?? [] {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            out.append(ChatMessage(.agent, t, date: date))
                        }
                    case "tool_use":
                        let name = (b["name"] as? String) ?? "Tool"
                        out.append(ChatMessage(.tool(name: name), ToolSummary.detail(name: name, input: b["input"] as? [String: Any] ?? [:]), date: date))
                    default: break
                    }
                }
            default: break
            }
        }
        return Array(out.suffix(limit))
    }

    private static func isHumanText(_ t: String) -> Bool {
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return !s.isEmpty && !s.hasPrefix("<") && !s.hasPrefix("[Request interrupted")
    }

    private static func transcriptURL(sessionId: String) -> URL? {
        let root = SessionDiscovery.claudeDir.appendingPathComponent("projects")
        let fm = FileManager.default
        for p in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let f = p.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: f.path) { return f }
        }
        return nil
    }
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
