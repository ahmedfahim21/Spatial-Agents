import AppKit
import Foundation

final class AppState: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var selectedId: UUID?
    @Published var focusedId: UUID?
    @Published var headYaw: Double = 0
    @Published var headStatus = "Starting head tracking…"
    @Published var isListening = false
    @Published var transcript = ""
    @Published var typed = ""
    @Published var log: [LogEntry] = []
    @Published var extraArgs = ""
    @Published var headPitch: Double = 0
    @Published var lastGesture = "—"
    @Published var pending: [PermissionRequest] = []
    @Published var serverStatus = "Starting permission server…"
    @Published var permissionTimeout: Double = 60
    @Published var gestureSensitivity: Double = 1 { didSet { tracker.sensitivity = gestureSensitivity } }
    @Published var focusWidth: Double = 30
    @Published var invertHead = false { didSet { tracker.invert = invertHead } }

    let audio = SpatialAudio()
    let tracker = HeadTracker()
    let speech = SpeechInput()
    let server = PermissionServer()

    /// Tools that can't change anything: allowed without asking so you aren't spammed.
    private let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS", "NotebookRead", "TodoWrite", "BashOutput", "Task"]

    private let defaultAzimuths: [Double] = [-60, 60, 180, -120, 120, 0]

    init() {
        tracker.onYaw = { [weak self] yaw in self?.handleYaw(yaw) }
        tracker.onStatus = { [weak self] s in DispatchQueue.main.async { self?.headStatus = s } }
        tracker.onPitch = { [weak self] p in self?.headPitch = p }
        tracker.onGesture = { [weak self] g in self?.handleGesture(g) }
        speech.onPartial = { [weak self] t in self?.transcript = t }
        server.onRequest = { [weak self] r in self?.handlePermission(r) }
        server.onStatus = { [weak self] s in self?.serverStatus = s }
        HookInstaller.install()
        server.start()
        ShellEnvironment.shared.resolve()
        tracker.start()
    }

    /// The agent you're facing, or else the one you clicked.
    var target: AgentSession? {
        let id = focusedId ?? selectedId
        return sessions.first { $0.id == id }
    }

    private func index(of id: UUID) -> Int? { sessions.firstIndex { $0.id == id } }

    // MARK: - Head

    private func handleYaw(_ yaw: Double) {
        headYaw = yaw
        audio.headYaw = yaw
        updateFocus()
    }

    func updateFocus() {
        var best: (id: UUID, diff: Double)?
        for s in sessions {
            let diff = abs(normalizeAngle(s.azimuth - headYaw))
            if diff <= focusWidth, diff < (best?.diff ?? .infinity) { best = (s.id, diff) }
        }
        let newId = best?.id
        guard newId != focusedId else { return }
        focusedId = newId
        if let newId { audio.ping(from: newId, high: false) }
    }

    func recenter() {
        tracker.recenter()
        appendLog(speaker: "Agentsphere", text: "Recentered: where you're looking is now the front.", fromUser: false)
    }

    // MARK: - Permissions

    /// The request a nod or shake answers: the one from the agent you're facing, else the oldest.
    var activeRequest: PermissionRequest? {
        pending.first { $0.agentId != nil && $0.agentId == focusedId } ?? pending.first
    }

    private func handlePermission(_ r: PermissionRequest) {
        let agent = sessions.first { $0.id == r.agentId }
            ?? sessions.first { $0.directory.standardizedFileURL.path == URL(fileURLWithPath: r.cwd).standardizedFileURL.path }
        let name = agent?.name ?? "Unknown agent"

        if readOnlyTools.contains(r.toolName) {
            r.respond(true, "Read-only tool, auto-allowed by Agentsphere.")
            appendLog(speaker: name, text: "Auto-allowed \(r.toolName).", fromUser: false)
            return
        }
        guard let agent else {
            r.respond(false, "Agentsphere doesn't know this session.")
            return
        }

        pending.append(r)
        if let i = index(of: agent.id) { sessions[i].status = .asking }
        appendLog(speaker: name, text: "Asks: \(r.summary)  [\(r.hash.prefix(10))]", fromUser: false)
        announce(r)

        let hash = r.hash, id = r.id
        DispatchQueue.main.asyncAfter(deadline: .now() + permissionTimeout) { [weak self] in
            guard let self, self.pending.contains(where: { $0.id == id }) else { return }
            self.resolve(id: id, hash: hash, allow: false, reason: "No answer within \(Int(self.permissionTimeout)) seconds, so it was denied.")
        }
    }

    private func announce(_ r: PermissionRequest) {
        guard let agent = sessions.first(where: { $0.id == r.agentId }) else { return }
        audio.ping(from: agent.id, high: true)
        audio.speak("\(sideName(agent.azimuth)): \(agent.name) \(r.summary). Nod or shake.", from: agent.id)
    }

    private func sideName(_ az: Double) -> String {
        switch az {
        case -30...30: return "In front"
        case 30...150: return "Right"
        case -150 ... -30: return "Left"
        default: return "Behind"
        }
    }

    private func handleGesture(_ g: HeadGesture) {
        lastGesture = "\(g.rawValue) at \(Date().formatted(date: .omitted, time: .standard))"
        guard let r = activeRequest else { return }
        let allow = g == .nod
        resolve(id: r.id, hash: r.hash, allow: allow,
                reason: allow ? "The user nodded to approve this." : "The user shook their head: denied. Don't retry this action; stop and say what you'll do instead.")
    }

    /// Approve or deny from the UI buttons (fallback for gestures).
    func decideActive(_ allow: Bool) {
        guard let r = activeRequest else { return }
        resolve(id: r.id, hash: r.hash, allow: allow,
                reason: allow ? "The user approved this." : "The user denied this. Don't retry this action; stop and say what you'll do instead.")
    }

    /// A decision only applies if it names the exact request and its tool+arguments hash.
    private func resolve(id: UUID, hash: String, allow: Bool, reason: String) {
        guard let i = pending.firstIndex(where: { $0.id == id }), pending[i].hash == hash else { return }
        let r = pending.remove(at: i)
        r.respond(allow, reason)
        if let agentId = r.agentId, let a = index(of: agentId) {
            if !pending.contains(where: { $0.agentId == agentId }) { sessions[a].status = .working }
            audio.ping(from: agentId, high: allow)
            audio.speak(allow ? "Approved." : "Denied.", from: agentId)
            appendLog(speaker: sessions[a].name, text: (allow ? "✅ Approved: " : "⛔️ Denied: ") + r.summary, fromUser: true)
        }
        if let next = pending.first { announce(next) }
    }

    // MARK: - Sessions

    func addSession() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Put an agent here"
        panel.message = "Pick the project folder this Claude Code session works in."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let azimuth = defaultAzimuths[sessions.count % defaultAzimuths.count]
        let session = AgentSession(name: url.lastPathComponent, directory: url, azimuth: azimuth)
        sessions.append(session)
        selectedId = session.id
        audio.register(id: session.id, azimuth: azimuth, voiceIndex: sessions.count - 1)
        audio.speak("\(session.name) is here.", from: session.id)
        updateFocus()
    }

    func removeSession(_ id: UUID) {
        for r in pending where r.agentId == id { resolve(id: r.id, hash: r.hash, allow: false, reason: "Agent removed from Agentsphere.") }
        audio.remove(id: id)
        sessions.removeAll { $0.id == id }
        if selectedId == id { selectedId = sessions.first?.id }
        if focusedId == id { focusedId = nil }
        updateFocus()
    }

    func setAzimuth(_ id: UUID, _ azimuth: Double) {
        guard let i = index(of: id) else { return }
        sessions[i].azimuth = normalizeAngle(azimuth)
        audio.setAzimuth(id: id, azimuth: sessions[i].azimuth)
        updateFocus()
    }

    // MARK: - Talking

    func toggleListening() {
        if isListening {
            isListening = false
            let text = speech.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = ""
            if !text.isEmpty { send(text) }
        } else {
            speech.begin { [weak self] error in
                guard let self else { return }
                if let error {
                    self.appendLog(speaker: "Agentsphere", text: error, fromUser: false)
                } else {
                    self.isListening = true
                }
            }
        }
    }

    func sendTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        typed = ""
        if !text.isEmpty { send(text) }
    }

    func send(_ text: String) {
        guard let t = target else {
            appendLog(speaker: "Agentsphere", text: "Face an agent (or click one) before talking.", fromUser: false)
            return
        }
        dispatch(text, to: t.id)
    }

    func repeatLast() {
        guard let t = target else { return }
        audio.speak(t.lastReply.isEmpty ? "Nothing yet." : Summarizer.spoken(t.lastReply, isError: t.status == .error), from: t.id)
    }

    private func dispatch(_ text: String, to id: UUID) {
        guard let i = index(of: id) else { return }
        let s = sessions[i]
        if s.status == .working || s.status == .asking {
            audio.speak("Still working on the last one.", from: id)
            return
        }
        sessions[i].status = .working
        appendLog(speaker: "You → \(s.name)", text: text, fromUser: true)
        audio.ping(from: id, high: true)

        let resume = s.claudeSessionId
        let dir = s.directory
        let args = extraArgs
        Task {
            let result = await ClaudeRunner.run(prompt: text, in: dir, resume: resume, extraArgs: args, agentId: id)
            await MainActor.run { self.finish(id: id, result: result) }
        }
    }

    private func finish(id: UUID, result: ClaudeResult) {
        guard let i = index(of: id) else { return }
        if let sid = result.sessionId { sessions[i].claudeSessionId = sid }
        sessions[i].lastReply = result.text
        sessions[i].status = result.isError ? .error : .waiting
        appendLog(speaker: sessions[i].name, text: result.text, fromUser: false)
        audio.speak(Summarizer.spoken(result.text, isError: result.isError), from: id)
    }

    func appendLog(speaker: String, text: String, fromUser: Bool) {
        log.append(LogEntry(speaker: speaker, text: text, fromUser: fromUser))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
