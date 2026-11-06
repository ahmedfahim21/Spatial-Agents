import Foundation

struct ClaudeResult {
    var text: String
    var sessionId: String?
    var isError: Bool
}

/// GUI apps don't get your shell's PATH, so we ask an interactive zsh where `claude` and `node` live.
final class ShellEnvironment {
    static let shared = ShellEnvironment()
    private let lock = NSLock()
    private var _claudePath: String?
    private var _path: String?

    var path: String? { lock.lock(); defer { lock.unlock() }; return _path }

    func resolve() {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-ilc", "echo __AGENTSPHERE_PATH__$PATH; command -v claude"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) { if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var foundPath: String?
            var foundClaude: String?
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init) {
                if let r = line.range(of: "__AGENTSPHERE_PATH__") {
                    foundPath = String(line[r.upperBound...])
                } else if line.hasPrefix("/"), line.hasSuffix("claude") {
                    foundClaude = line
                }
            }
            self.lock.lock()
            self._path = foundPath
            self._claudePath = foundClaude
            self.lock.unlock()
        }
    }

    func claudeExecutable() -> String? {
        lock.lock()
        let found = _claudePath
        lock.unlock()
        if let found, FileManager.default.isExecutableFile(atPath: found) { return found }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Runs one turn of a Claude Code session headlessly and returns its reply.
/// Something Claude did mid-turn, streamed so the chat shows progress live.
enum RunEvent {
    case text(String)
    case tool(name: String, detail: String)
}

/// Runs one turn of a Claude Code session headlessly and returns its reply.
/// Uses stream-json so text and tool calls arrive as they happen.
enum ClaudeRunner {
    static func run(prompt: String, in dir: URL, resume: String?, fork: Bool = false, extraArgs: String, agentId: UUID,
                    onEvent: @escaping (RunEvent) -> Void = { _ in }) async -> ClaudeResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(prompt: prompt, in: dir, resume: resume, fork: fork, extraArgs: extraArgs,
                                               agentId: agentId, onEvent: onEvent))
            }
        }
    }

    private static func runSync(prompt: String, in dir: URL, resume: String?, fork: Bool, extraArgs: String, agentId: UUID,
                                onEvent: @escaping (RunEvent) -> Void) -> ClaudeResult {
        guard let claude = ShellEnvironment.shared.claudeExecutable() else {
            return ClaudeResult(text: "I couldn't find the claude command. Install Claude Code first.", sessionId: nil, isError: true)
        }

        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose"]
        if let resume {
            args += ["--resume", resume]
            if fork { args.append("--fork-session") }
        }
        // Every tool call goes through the PreToolUse hook, which asks Agentsphere.
        args += ["--settings", HookInstaller.settingsPath]
        args += extraArgs.split(separator: " ").map(String.init)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        if let path = ShellEnvironment.shared.path { env["PATH"] = path }
        env["AGENTSPHERE_AGENT"] = agentId.uuidString
        p.environment = env

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        let errBox = DataBox()
        err.fileHandleForReading.readabilityHandler = { handle in errBox.append(handle.availableData) }

        do { try p.run() } catch {
            return ClaudeResult(text: "Couldn't start Claude: \(error.localizedDescription)", sessionId: nil, isError: true)
        }

        var result: ClaudeResult?
        var sessionId: String?
        var lastText = ""
        var pending = Data()
        let reader = out.fileHandleForReading
        func handle(line: Data) {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if let sid = obj["session_id"] as? String { sessionId = sid }
            switch obj["type"] as? String {
            case "assistant":
                let blocks = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                for b in blocks {
                    switch b["type"] as? String {
                    case "text":
                        if let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            lastText = t
                            onEvent(.text(t))
                        }
                    case "tool_use":
                        let name = (b["name"] as? String) ?? "Tool"
                        onEvent(.tool(name: name, detail: ToolSummary.detail(name: name, input: b["input"] as? [String: Any] ?? [:])))
                    default: break
                    }
                }
            case "result":
                let text = (obj["result"] as? String) ?? lastText
                let isErr = (obj["is_error"] as? Bool) ?? false
                let fallback = (obj["subtype"] as? String) ?? "Done."
                result = ClaudeResult(text: text.isEmpty ? fallback : text, sessionId: sessionId, isError: isErr)
            default: break
            }
        }
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                handle(line: pending[pending.startIndex..<nl])
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        if !pending.isEmpty { handle(line: pending) }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil

        if var r = result {
            if p.terminationStatus != 0 && !r.isError { r.isError = true }
            return r
        }
        let stderr = errBox.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeResult(text: stderr.isEmpty ? (lastText.isEmpty ? "Claude exited without a reply." : lastText) : stderr,
                            sessionId: sessionId, isError: p.terminationStatus != 0)
    }
}

/// One-line descriptions of tool calls, shared by the chat and permission prompts.
enum ToolSummary {
    static func detail(name: String, input: [String: Any]) -> String {
        func str(_ k: String) -> String { (input[k] as? String) ?? "" }
        func file(_ k: String) -> String { (str(k) as NSString).lastPathComponent }
        switch name {
        case "Bash": return str("command")
        case "Read", "Edit", "MultiEdit", "Write": return file("file_path")
        case "NotebookEdit": return file("notebook_path")
        case "Grep": return str("pattern")
        case "Glob": return str("pattern")
        case "WebFetch": return str("url")
        case "WebSearch": return str("query")
        case "Task": return str("description")
        default: return ""
        }
    }
}

private final class DataBox {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
