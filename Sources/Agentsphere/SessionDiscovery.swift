import Foundation

/// A Claude Code session found on disk, live or recent.
struct DiscoveredSession: Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
    let directory: URL
    var title: String
    var lastPrompt: String
    var lastActive: Date
    /// Open right now in a terminal (or other Claude Code process).
    var isLive = false
    /// "busy" / "idle" for live sessions.
    var liveStatus: String?

    var folderName: String { directory.lastPathComponent }
}

/// Finds Claude Code sessions without the user opening Finder.
///
/// Sources (both internal to Claude Code, so read defensively):
/// - `~/.claude/sessions/<pid>.json`: one file per running session.
/// - `~/.claude/projects/<folder>/<session-id>.jsonl`: every session's transcript.
enum SessionDiscovery {
    static var claudeDir: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude") }

    static func scan(limit: Int = 60) -> [DiscoveredSession] {
        let live = liveSessions()
        var byId: [String: DiscoveredSession] = [:]

        for s in recentTranscripts(limit: limit) { byId[s.sessionId] = s }
        for l in live {
            if var s = byId[l.sessionId] {
                s.isLive = true
                s.liveStatus = l.liveStatus
                if s.title.isEmpty { s.title = l.title }
                s.lastActive = max(s.lastActive, l.lastActive)
                byId[l.sessionId] = s
            } else {
                byId[l.sessionId] = l
            }
        }
        return byId.values.sorted { a, b in
            if a.isLive != b.isLive { return a.isLive }
            return a.lastActive > b.lastActive
        }
    }

    // MARK: - Live

    private static func liveSessions() -> [DiscoveredSession] {
        let dir = claudeDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [DiscoveredSession] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String else { continue }
            // Stale files outlive crashed processes; only trust ones whose pid is alive.
            if let pid = obj["pid"] as? Int, kill(pid_t(pid), 0) != 0, errno == ESRCH { continue }
            let updated = (obj["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            out.append(DiscoveredSession(
                sessionId: sid,
                directory: URL(fileURLWithPath: cwd),
                title: (obj["name"] as? String) ?? "",
                lastPrompt: "",
                lastActive: updated,
                isLive: true,
                liveStatus: obj["status"] as? String
            ))
        }
        return out
    }

    // MARK: - Transcripts

    private static func recentTranscripts(limit: Int) -> [DiscoveredSession] {
        let root = claudeDir.appendingPathComponent("projects")
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }

        var files: [(url: URL, date: Date)] = []
        for p in projects {
            guard let items = try? fm.contentsOfDirectory(at: p, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in items where f.pathExtension == "jsonl" {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((f, d))
            }
        }
        files.sort { $0.date > $1.date }

        return files.prefix(limit).compactMap { parse($0.url, modified: $0.date) }
    }

    /// Reads only the head (for cwd) and tail (for the latest title/prompt) of a transcript,
    /// so even huge sessions scan instantly.
    private static func parse(_ url: URL, modified: Date) -> DiscoveredSession? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 256 * 1024

        try? h.seek(toOffset: 0)
        let head = (try? h.read(upToCount: Int(chunk))) ?? Data()
        let tailStart = size > chunk ? size - chunk : 0
        try? h.seek(toOffset: tailStart)
        let tail = (try? h.readToEnd()) ?? Data()

        var cwd: String?
        var title = ""
        var prompt = ""
        for line in lines(head) {
            if cwd == nil, let c = line["cwd"] as? String { cwd = c }
            if cwd != nil { break }
        }
        for line in lines(tail) {
            if let c = line["cwd"] as? String { cwd = c }
            switch line["type"] as? String {
            case "ai-title": if let t = line["aiTitle"] as? String { title = t }
            case "summary": if title.isEmpty, let t = line["summary"] as? String { title = t }
            case "last-prompt": if let p = line["lastPrompt"] as? String { prompt = p }
            default: break
            }
        }
        guard let cwd else { return nil }
        return DiscoveredSession(
            sessionId: url.deletingPathExtension().lastPathComponent,
            directory: URL(fileURLWithPath: cwd),
            title: title,
            lastPrompt: prompt.replacingOccurrences(of: "\n", with: " "),
            lastActive: modified
        )
    }

    /// Parses complete JSON lines; partial lines at chunk edges are skipped.
    private static func lines(_ data: Data) -> [[String: Any]] {
        data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }
}
