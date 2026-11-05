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
    @Published var extraArgs = "--permission-mode acceptEdits"
    @Published var focusWidth: Double = 30
    @Published var invertHead = false { didSet { tracker.invert = invertHead } }

    let audio = SpatialAudio()
    let tracker = HeadTracker()
    let speech = SpeechInput()

    private let defaultAzimuths: [Double] = [-60, 60, 180, -120, 120, 0]

    init() {
        tracker.onYaw = { [weak self] yaw in self?.handleYaw(yaw) }
        tracker.onStatus = { [weak self] s in DispatchQueue.main.async { self?.headStatus = s } }
        speech.onPartial = { [weak self] t in self?.transcript = t }
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
        if s.status == .working {
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
            let result = await ClaudeRunner.run(prompt: text, in: dir, resume: resume, extraArgs: args)
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
