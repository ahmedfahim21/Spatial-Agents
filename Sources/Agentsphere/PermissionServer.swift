import CryptoKit
import Foundation
import Network

/// One tool call a Claude session wants to make, held open until you nod or shake.
struct PermissionRequest: Identifiable {
    let id = UUID()
    let agentId: UUID?
    let cwd: String
    let toolName: String
    let toolInput: [String: Any]
    /// SHA-256 of the exact tool name + arguments. A decision only ever answers this hash.
    let hash: String
    let date = Date()
    let respond: (Bool, String) -> Void

    var summary: String {
        func str(_ k: String) -> String { (toolInput[k] as? String) ?? "" }
        func file(_ k: String) -> String { (str(k) as NSString).lastPathComponent }
        switch toolName {
        case "Bash":
            let cmd = str("command")
            return "wants to run \(cmd.count > 90 ? String(cmd.prefix(90)) + "…" : cmd)"
        case "Edit", "MultiEdit": return "wants to edit \(file("file_path"))"
        case "Write": return "wants to write \(file("file_path"))"
        case "NotebookEdit": return "wants to edit notebook \(file("notebook_path"))"
        case "WebFetch": return "wants to fetch \(str("url"))"
        case "WebSearch": return "wants to search the web for \(str("query"))"
        default: return "wants to use \(toolName)"
        }
    }

    static func hash(tool: String, input: [String: Any]) -> String {
        let args = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        var h = SHA256()
        h.update(data: Data(tool.utf8))
        h.update(data: Data([0]))
        h.update(data: args)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Minimal HTTP server on 127.0.0.1. The Claude Code PreToolUse hook POSTs the hook
/// input to /permission and the response body is the hook's JSON output.
final class PermissionServer {
    static let port: UInt16 = 7777
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agentsphere.permission-server")

    /// Called on the main queue for every tool call.
    var onRequest: ((PermissionRequest) -> Void)?
    var onStatus: ((String) -> Void)?

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self] s in
                let msg: String?
                switch s {
                case .ready: msg = "Permission server listening on 127.0.0.1:\(Self.port)"
                case .failed(let e): msg = "Permission server failed: \(e)"
                default: msg = nil
                }
                if let msg { DispatchQueue.main.async { self?.onStatus?(msg) } }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            onStatus?("Permission server couldn't start: \(error)")
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
    }

    private func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let (headers, body) = Self.parse(buf) {
                self.handle(c, headers: headers, body: body)
            } else if done || error != nil {
                c.cancel()
            } else {
                self.read(c, buffer: buf)
            }
        }
    }

    /// Returns headers + body once the whole request has arrived.
    private static func parse(_ buf: Data) -> ([String: String], Data)? {
        guard let sep = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<sep.lowerBound], as: UTF8.self)
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buf[sep.upperBound...]
        guard body.count >= length else { return nil }
        return (headers, Data(body.prefix(length)))
    }

    private func handle(_ c: NWConnection, headers: [String: String], body: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let tool = obj["tool_name"] as? String else {
            send(c, json: [:])
            return
        }
        let input = (obj["tool_input"] as? [String: Any]) ?? [:]
        let agentId = headers["x-agentsphere-agent"].flatMap(UUID.init(uuidString:))
        let answered = Flag()
        let req = PermissionRequest(
            agentId: agentId,
            cwd: (obj["cwd"] as? String) ?? "",
            toolName: tool,
            toolInput: input,
            hash: PermissionRequest.hash(tool: tool, input: input)
        ) { [weak self] allow, reason in
            self?.queue.async {
                guard !answered.value else { return }
                answered.value = true
                self?.send(c, json: ["hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": allow ? "allow" : "deny",
                    "permissionDecisionReason": reason,
                ]])
            }
        }
        DispatchQueue.main.async { self.onRequest?(req) }
    }

    private func send(_ c: NWConnection, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var resp = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        resp.append(body)
        c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
    }
}

private final class Flag { var value = false }

/// Writes the hook script + a settings file that `claude --settings` loads, so the
/// agents' repos are never touched.
enum HookInstaller {
    static var dir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Agentsphere", isDirectory: true)
    }
    static var settingsPath: String { dir.appendingPathComponent("hook-settings.json").path }

    static func install() {
        let script = dir.appendingPathComponent("pretooluse.sh")
        let sh = """
        #!/bin/bash
        # Agentsphere PreToolUse hook: hands the tool call to the app and prints its decision.
        # If the app isn't running, prints nothing so Claude's normal permission rules apply.
        curl -s --max-time 110 -X POST \\
          -H "Content-Type: application/json" \\
          -H "X-Agentsphere-Agent: ${AGENTSPHERE_AGENT:-}" \\
          --data-binary @- http://127.0.0.1:\(PermissionServer.port)/permission || true

        """
        let settings: [String: Any] = ["hooks": ["PreToolUse": [[
            "matcher": "*",
            "hooks": [["type": "command", "command": "\"\(script.path)\"", "timeout": 120]],
        ]]]]
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try sh.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: URL(fileURLWithPath: settingsPath))
        } catch {
            print("Agentsphere hook install failed: \(error)")
        }
    }
}
