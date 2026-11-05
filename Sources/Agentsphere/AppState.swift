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
    @Published var voiceStatus = ""
    @Published var voiceEngine = ""
    @Published var elevenKeyInput = ""
    @Published var showDiscover = false
    @Published var discovered: [DiscoveredSession] = []
    @Published var scanning = false
    @Published var permissionTimeout: Double = 60
    @Published var gestureSensitivity: Double = 1 { didSet { tracker.sensitivity = gestureSensitivity } }
    @Published var focusWidth: Double = 30
    @Published var invertHead = false { didSet { tracker.invert = invertHead } }

    let audio = SpatialAudio()
    let tracker = HeadTracker()
    let speech = SpeechInput()
    let server = PermissionServer()
    let lab = SoundLab()

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
        audio.voices.onStatus = { [weak self] s in self?.voiceStatus = s }
        voiceEngine = audio.voices.activeLabel
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

    /// Focus as it was while the head was steady. Gestures answer this agent, so a
    /// shake that swings past a neighbour still answers the one you were facing.
    private var steadyFocusId: UUID?
    private var candidateId: UUID?
    private var candidateSince = Date.distantPast

    private func handleYaw(_ yaw: Double) {
        headYaw = yaw
        audio.headYaw = yaw
        lab.setHeadYaw(yaw)
        updateFocus()
        if abs(tracker.yawSpeed) < 40 { steadyFocusId = focusedId }
    }

    /// Picks the agent you're facing, with stickiness so focus doesn't flicker at the edges:
    /// keep the current agent until you're clearly past it, and only switch after a short dwell.
    func updateFocus(immediate: Bool = false) {
        let margin = 8.0
        func diff(_ s: AgentSession) -> Double { abs(normalizeAngle(s.azimuth - headYaw)) }

        var best: (id: UUID, diff: Double)?
        for s in sessions {
            let d = diff(s)
            if d <= focusWidth, d < (best?.diff ?? .infinity) { best = (s.id, d) }
        }
        var newId = best?.id
        if let cur = sessions.first(where: { $0.id == focusedId }), diff(cur) <= focusWidth + margin {
            // Stay on the current agent unless another is clearly closer.
            if let b = best, b.id != cur.id, b.diff + margin < diff(cur) { newId = b.id } else { newId = cur.id }
        }

        guard newId != focusedId else { candidateId = nil; return }
        if !immediate {
            if candidateId != newId { candidateId = newId; candidateSince = Date(); return }
            // Fast sweeps through an agent shouldn't select it.
            if Date().timeIntervalSince(candidateSince) < 0.15 || abs(tracker.yawSpeed) > 150 { return }
        }
        candidateId = nil
        focusedId = newId
        if let newId { audio.ping(from: newId, high: false) }
    }

    func recenter() {
        tracker.recenter()
        appendLog(speaker: "Agentsphere", text: "Recentered: where you're looking is now the front.", fromUser: false)
    }

    // MARK: - Voice

    func saveElevenLabsKey() {
        audio.voices.elevenLabs.setKey(elevenKeyInput)
        elevenKeyInput = ""
        voiceEngine = audio.voices.activeLabel
        voiceStatus = audio.voices.elevenLabs.hasStoredKey ? "Key saved in Keychain" : "Key removed"
    }

    func testVoice() {
        guard let t = target ?? sessions.first(where: { $0.id == selectedId }) ?? sessions.first else {
            voiceStatus = "Add an agent first, then test its voice."
            return
        }
        audio.speak("Hi, I'm \(t.name). I'll ask here when I need your permission.", from: t.id)
    }

    // MARK: - Permissions

    /// The request a nod or shake answers: the one from the agent you're facing, else the oldest.
    var activeRequest: PermissionRequest? {
        let id = steadyFocusId ?? focusedId
        return pending.first { $0.agentId != nil && $0.agentId == id } ?? pending.first
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
        place(AgentSession(name: url.lastPathComponent, directory: url, azimuth: 0))
    }

    /// Finds Claude Code sessions on this Mac (live first, then recent).
    func refreshDiscovery() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = SessionDiscovery.scan()
            DispatchQueue.main.async {
                self.discovered = found
                self.scanning = false
            }
        }
    }

    func isAttached(_ d: DiscoveredSession) -> Bool {
        sessions.contains { $0.claudeSessionId == d.sessionId }
    }

    /// Puts a discovered session in the room. `fresh` starts a new conversation in that folder.
    func attach(_ d: DiscoveredSession, fresh: Bool = false) {
        var name = d.folderName
        let taken = Set(sessions.map(\.name))
        var n = 2
        while taken.contains(name) { name = "\(d.folderName) \(n)"; n += 1 }
        var s = AgentSession(name: name, directory: d.directory, azimuth: 0)
        if !fresh {
            s.claudeSessionId = d.sessionId
            s.forkNext = d.isLive
            s.title = d.title
        }
        place(s)
        appendLog(speaker: "Agentsphere",
                  text: fresh ? "New session in \(d.directory.path)."
                      : d.isLive ? "Attached to live session “\(d.title)” — it's open elsewhere, so the first turn forks it."
                      : "Resuming “\(d.title.isEmpty ? d.sessionId : d.title)”.",
                  fromUser: false)
    }

    private func place(_ new: AgentSession) {
        var session = new
        session.azimuth = defaultAzimuths[sessions.count % defaultAzimuths.count]
        sessions.append(session)
        selectedId = session.id
        audio.register(id: session.id, azimuth: session.azimuth, voiceIndex: sessions.count - 1)
        audio.speak("\(session.name) is here.", from: session.id)
        updateFocus(immediate: true)
    }

    func removeSession(_ id: UUID) {
        for r in pending where r.agentId == id { resolve(id: r.id, hash: r.hash, allow: false, reason: "Agent removed from Agentsphere.") }
        audio.remove(id: id)
        sessions.removeAll { $0.id == id }
        if selectedId == id { selectedId = sessions.first?.id }
        if focusedId == id { focusedId = nil }
        updateFocus(immediate: true)
    }

    func setAzimuth(_ id: UUID, _ azimuth: Double) {
        guard let i = index(of: id) else { return }
        sessions[i].azimuth = normalizeAngle(azimuth)
        audio.setAzimuth(id: id, azimuth: sessions[i].azimuth)
        updateFocus(immediate: true)
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
        let fork = s.forkNext
        let dir = s.directory
        let args = extraArgs
        Task {
            let result = await ClaudeRunner.run(prompt: text, in: dir, resume: resume, fork: fork, extraArgs: args, agentId: id)
            await MainActor.run { self.finish(id: id, result: result) }
        }
    }

    private func finish(id: UUID, result: ClaudeResult) {
        guard let i = index(of: id) else { return }
        if let sid = result.sessionId {
            sessions[i].claudeSessionId = sid
            sessions[i].forkNext = false
        }
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
