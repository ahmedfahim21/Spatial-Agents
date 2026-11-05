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
enum ClaudeRunner {
    static func run(prompt: String, in dir: URL, resume: String?, fork: Bool = false, extraArgs: String, agentId: UUID) async -> ClaudeResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runSync(prompt: prompt, in: dir, resume: resume, fork: fork, extraArgs: extraArgs, agentId: agentId))
            }
        }
    }

    private static func runSync(prompt: String, in dir: URL, resume: String?, fork: Bool, extraArgs: String, agentId: UUID) -> ClaudeResult {
        guard let claude = ShellEnvironment.shared.claudeExecutable() else {
            return ClaudeResult(text: "I couldn't find the claude command. Install Claude Code first.", sessionId: nil, isError: true)
        }

        var args = ["-p", prompt, "--output-format", "json"]
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
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = (obj["result"] as? String) ?? ""
            let sid = obj["session_id"] as? String
            let isErr = (obj["is_error"] as? Bool) ?? (p.terminationStatus != 0)
            let fallback = (obj["subtype"] as? String) ?? "Done."
            return ClaudeResult(text: text.isEmpty ? fallback : text, sessionId: sid, isError: isErr)
        }

        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = errBox.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeResult(text: raw.isEmpty ? stderr : raw, sessionId: nil, isError: p.terminationStatus != 0)
    }
}

private final class DataBox {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
