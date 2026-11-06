import AVFoundation
import Combine
import CoreLocation
import SwiftUI

enum ConversationPhase: Equatable {
    case idle, greeting, listening, thinking, speaking
}

/// The phone app's brain. Two kinds of agents share one spatial scene:
/// - body-anchored agents sit in a ring around you and travel with you (BodyFollower frame);
/// - geo-anchored agents sit where they are in the world (compass frame), once you've arrived.
/// Look at one for 3 seconds and it wakes up; then you talk hands-free.
@MainActor
final class MobileState: ObservableObject {
    let head = HeadMotion()
    let voices = VoiceRouter()
    let audio: SpatialAudio
    let speech = SpeechInput()
    let location = LocationService()
    let haptics = Haptics()
    private let tracker = HeadTracker()
    private let backend = Backend.shared

    // MARK: Published state

    @Published var myAgents: [Agent] = []
    @Published var nearby: [Agent] = []
    @Published var backendStatus = ""
    @Published var loading = false

    /// Body-anchored agents are around you.
    @Published var withMe = true { didSet { syncPlacement() } }
    @Published var findTargetId: UUID? { didSet { if oldValue != findTargetId { findTargetChanged() } } }
    @Published private(set) var arrived: Set<UUID> = []

    @Published private(set) var focusedId: UUID?
    @Published private(set) var stareProgress: Double = 0
    @Published private(set) var activeId: UUID?
    @Published private(set) var phase: ConversationPhase = .idle
    @Published private(set) var transcript = ""
    @Published var conversations: [UUID: [ChatMessage]] = [:]

    @Published var trackingStatus = "Starting…"
    @Published private(set) var hasHeadData = false
    @Published var lastGesture: HeadGesture?
    @Published var route = ""
    @Published var highQualityMic = false
    @Published var voiceStatus = ""

    // MARK: Head frames

    /// Head yaw relative to your body (body agents).
    private var yawBody: Double = 0
    /// Head yaw in the tracker's fixed frame.
    private var yawFixed: Double = 0
    /// Compass heading of the tracker's fixed-frame zero; nil until calibrated.
    private var worldOffset: Double?
    private var lastHeadAt = Date.distantPast
    private var lastYawLog = Date.distantPast

    /// Where your head points in the world, degrees from true north.
    var headWorld: Double? {
        if hasHeadData, let o = worldOffset { return normalize360(o + yawFixed) }
        return location.heading   // no AirPods: the phone is the pointer
    }

    // MARK: Placement

    private var placed: Set<UUID> = []
    /// Body agents' fixed slots around you.
    private var bodySlots: [UUID: Double] = [:]
    /// Geo agents' bearings, frozen when close or when GPS is poor so they don't jitter.
    private var lockedBearing: [UUID: Double] = [:]
    private var lastFocusAt = Date()
    private var lookAwaySince: Date?
    private var lastHeardAt = Date()
    private var listenStartedAt = Date()
    private var lastBeacon = Date.distantPast
    private var lastNearbyFetch: (at: Date, where: CLLocationCoordinate2D)?
    private var timer: Timer?
    private var bag: Set<AnyCancellable> = []

    init() {
        AudioSession.configure()
        audio = SpatialAudio(voices: voices)
        audio.headYaw = 0   // positions are computed here, already head-relative
        voices.primary = ServerVoice()
        voices.onStatus = { [weak self] s in self?.voiceStatus = s }

        tracker.onStatus = { [weak self] s in
            print("Agentsphere: tracking status: \(s)")
            self?.trackingStatus = s
        }
        tracker.onYaw = { [weak self] y in
            guard let self else { return }
            self.yawBody = y
            self.head.yaw = y
            self.lastHeadAt = Date()
            if !self.hasHeadData {
                self.hasHeadData = true
                print("Agentsphere: head motion flowing")
            }
            if Date().timeIntervalSince(self.lastYawLog) > 2 {
                self.lastYawLog = Date()
                print(String(format: "Agentsphere: head yaw %.0f° (fixed %.0f°) pitch %.0f°", y, self.yawFixed, self.head.pitch))
            }
            self.updateScene()
        }
        tracker.onFixedYaw = { [weak self] y in self?.yawFixed = y }
        tracker.onPitch = { [weak self] p in self?.head.pitch = p }
        tracker.onGesture = { [weak self] g in self?.handleGesture(g) }
        tracker.isEngaged = { [weak self] in
            guard let self else { return false }
            return self.activeId != nil && self.phase != .idle
        }
        tracker.start()

        speech.onPartial = { [weak self] t in self?.heard(t) }
        audio.onSpeakingChanged = { [weak self] speaking in self?.speakingChanged(speaking) }
        audio.beforeSpeaking = { [weak self] in self?.releaseMicForSpeech() ?? false }

        location.start()
        location.$coordinate.sink { [weak self] _ in
            Task { @MainActor in self?.locationChanged() }
        }.store(in: &bag)
        location.$heading.sink { [weak self] _ in
            Task { @MainActor in self?.calibrateWorld(); self?.updateScene() }
        }.store(in: &bag)

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        refreshRoute()
        Task { await refreshMine() }
    }

    // MARK: - Agents

    var bodyAgents: [Agent] { myAgents.filter { !$0.isGeo } }

    func agent(_ id: UUID?) -> Agent? {
        guard let id else { return nil }
        return myAgents.first { $0.id == id } ?? nearby.first { $0.id == id }
    }

    func refreshMine() async {
        guard Config.isConfigured else { return }
        do {
            myAgents = try await backend.myAgents()
            backendStatus = ""
            syncPlacement()
        } catch {
            backendStatus = error.localizedDescription
        }
    }

    func refreshNearby(force: Bool = false) async {
        guard Config.isConfigured, let here = location.coordinate else { return }
        if !force, let last = lastNearbyFetch,
           Date().timeIntervalSince(last.at) < 30, GeoMath.distance(last.where, here) < 25 { return }
        lastNearbyFetch = (Date(), here)
        loading = true
        defer { loading = false }
        do {
            nearby = try await backend.nearby(lat: here.latitude, lng: here.longitude, km: 5)
            backendStatus = ""
            updateArrivals()
        } catch {
            backendStatus = error.localizedDescription
        }
    }

    func create(_ new: NewAgent) async throws -> Agent {
        let a = try await backend.create(new)
        myAgents.insert(a, at: 0)
        syncPlacement()
        if a.isGeo { await refreshNearby(force: true) }
        return a
    }

    func delete(_ a: Agent) async {
        do {
            try await backend.delete(a.id)
            myAgents.removeAll { $0.id == a.id }
            nearby.removeAll { $0.id == a.id }
            if activeId == a.id { endConversation() }
            if findTargetId == a.id { findTargetId = nil }
            syncPlacement()
        } catch {
            backendStatus = error.localizedDescription
        }
    }

    // MARK: - Geo

    func distance(to a: Agent) -> Double? {
        guard let here = location.coordinate, let lat = a.lat, let lng = a.lng else { return nil }
        return GeoMath.distance(here, CLLocationCoordinate2D(latitude: lat, longitude: lng))
    }

    func bearing(to a: Agent) -> Double? {
        if let locked = lockedBearing[a.id] { return locked }
        guard let here = location.coordinate, let lat = a.lat, let lng = a.lng else { return nil }
        return GeoMath.bearing(from: here, to: CLLocationCoordinate2D(latitude: lat, longitude: lng))
    }

    func arrivalRadius(for a: Agent) -> Double {
        GeoMath.arrivalRadius(agentRadius: a.radiusM, accuracy: location.accuracy)
    }

    /// Where to point the on-screen arrow: relative to the phone's heading.
    func screenArrow(to a: Agent) -> Double? {
        guard let b = bearing(to: a), let h = location.heading else { return nil }
        return b - h
    }

    private func locationChanged() {
        Task { await refreshNearby() }
        updateArrivals()
    }

    private func updateArrivals() {
        var now = arrived
        for a in nearby where a.isGeo {
            guard let d = distance(to: a) else { continue }
            let r = arrivalRadius(for: a)
            if d <= r {
                if !now.contains(a.id) {
                    now.insert(a.id)
                    didArrive(at: a)
                }
                // Close up, GPS bearings swing wildly; freeze the direction.
                if lockedBearing[a.id] == nil, d < 10 || location.isPoorFix, let b = bearing(to: a) {
                    lockedBearing[a.id] = b
                }
            } else if d > r + 10, now.contains(a.id) {
                now.remove(a.id)
                lockedBearing[a.id] = nil
                if activeId == a.id { endConversation() }
            }
        }
        if now != arrived { arrived = now; syncPlacement() }
        updateFindFeedback()
    }

    private func didArrive(at a: Agent) {
        haptics.arrived()
        if findTargetId == a.id { haptics.distance = nil }
        ensurePlaced(a)
        audio.setGain(id: a.id, gain: 1)
        audio.cue(.chime, from: a.id)
    }

    /// Find mode: haptics and a beacon from the agent's real direction, stronger as you near it.
    private func findTargetChanged() {
        haptics.distance = nil
        syncPlacement()
        updateFindFeedback()
    }

    private func updateFindFeedback() {
        guard let id = findTargetId, let a = agent(id), let d = distance(to: a) else {
            haptics.distance = nil
            return
        }
        if arrived.contains(id) {
            haptics.distance = nil
            return
        }
        let beyond = max(0, d - arrivalRadius(for: a))
        haptics.distance = beyond
        audio.setGain(id: id, gain: GeoMath.beaconGain(distance: beyond))
    }

    private func beaconTick() {
        guard let id = findTargetId, !arrived.contains(id), let a = agent(id), let d = distance(to: a) else { return }
        let beyond = max(0, d - arrivalRadius(for: a))
        let interval = max(0.7, GeoMath.hapticPulse(distance: beyond).interval * 1.6)
        guard Date().timeIntervalSince(lastBeacon) >= interval else { return }
        lastBeacon = Date()
        audio.ping(from: id, high: beyond < 40)
    }

    /// Ties the AirPods' fixed frame to true north. While you look down at the phone,
    /// your head points where the phone points, so the compass tells us the offset.
    private func calibrateWorld() {
        guard hasHeadData, let h = location.heading, location.headingAccuracy < 30 else { return }
        let target = normalize360(h - yawFixed)
        guard let current = worldOffset else { worldOffset = target; return }
        let lookingAtPhone = head.pitch < -12
        let alpha = lookingAtPhone ? 0.08 : 0.005   // slow drift correction otherwise
        worldOffset = normalize360(current + normalizeAngle(target - current) * alpha)
    }

    // MARK: - Spatial scene

    private func ensurePlaced(_ a: Agent) {
        guard !placed.contains(a.id) else { return }
        audio.register(id: a.id, azimuth: 0, voiceIndex: a.voiceIndex)
        placed.insert(a.id)
    }

    /// Body agents (if "with me"), arrived geo agents, and the Find target's beacon.
    private func syncPlacement() {
        var want = Set<UUID>()
        if withMe { for a in bodyAgents { want.insert(a.id) } }
        want.formUnion(arrived)
        if let f = findTargetId { want.insert(f) }
        if let active = activeId { want.insert(active) }

        for id in placed.subtracting(want) {
            audio.remove(id: id)
            placed.remove(id)
        }
        for id in want.subtracting(placed) { if let a = agent(id) { ensurePlaced(a) } }

        // Body agents take fixed slots, front first, so the first one is right ahead.
        let slots: [Double] = [0, -70, 70, -140, 140, 180, -35, 35]
        let body = bodyAgents
        bodySlots = Dictionary(uniqueKeysWithValues: body.enumerated().map { ($1.id, slots[$0 % slots.count]) })
        updateScene()
    }

    /// Angle of an agent relative to where your head points (0 = straight ahead, + = right).
    func relativeAngle(_ id: UUID) -> Double? {
        if let slot = bodySlots[id], withMe { return normalizeAngle(slot - yawBody) }
        guard let a = agent(id), a.isGeo, let b = bearing(to: a), let h = headWorld else { return nil }
        return normalizeAngle(b - h)
    }

    /// Agents you can stare at right now.
    var talkable: [Agent] {
        (withMe ? bodyAgents : []) + nearby.filter { arrived.contains($0.id) }
    }

    private func updateScene() {
        for id in placed {
            if let rel = relativeAngle(id) { audio.setAzimuth(id: id, azimuth: rel) }
        }
        updateFocus()
    }

    private func updateFocus() {
        let candidates = talkable.compactMap { a in relativeAngle(a.id).map { (a.id, abs($0)) } }
        var next: UUID?
        if let cur = focusedId, let c = candidates.first(where: { $0.0 == cur }), c.1 < 32 {
            next = cur   // hysteresis: keep focus until clearly looking elsewhere
        } else if let best = candidates.filter({ $0.1 < 22 }).min(by: { $0.1 < $1.1 }) {
            next = best.0
        }
        if next != focusedId {
            focusedId = next
            stareProgress = 0
            lastFocusAt = Date()
            if let n = next, n != activeId {
                audio.ping(from: n, high: false)
                haptics.tap(intensity: 0.4, sharpness: 0.3)
            }
        }
    }

    private func tick() {
        if hasHeadData, Date().timeIntervalSince(lastHeadAt) > 3 {
            hasHeadData = false
            trackingStatus = "AirPods head tracking paused. Put your AirPods in to look around."
        }
        if !hasHeadData { updateScene() }   // phone heading drives focus without AirPods
        beaconTick()

        // Stare to wake: 3 s of steady attention.
        if let f = focusedId, f != activeId {
            let p = min(1, Date().timeIntervalSince(lastFocusAt) / 3)
            if p != stareProgress { stareProgress = p }
            if p >= 1, let a = agent(f) { wake(a) }
        } else if stareProgress != 0 {
            stareProgress = 0
        }

        // Conversation housekeeping.
        guard let active = activeId else { return }
        let looking = relativeAngle(active).map { abs($0) < 50 } ?? true
        if looking { lookAwaySince = nil } else if lookAwaySince == nil { lookAwaySince = Date() }
        let idle = phase == .listening && transcript.isEmpty
        if idle, let since = lookAwaySince, Date().timeIntervalSince(since) > 5 { endConversation(); return }
        if phase == .listening {
            if !transcript.isEmpty, Date().timeIntervalSince(lastHeardAt) > 1.3 {
                send(transcript)
            } else if transcript.isEmpty, Date().timeIntervalSince(listenStartedAt) > 40 {
                endConversation()
            }
        }
    }

    // MARK: - Conversation

    func messages(for id: UUID) -> [ChatMessage] { conversations[id] ?? [] }

    private func post(_ m: ChatMessage, to id: UUID) {
        conversations[id, default: []].append(m)
    }

    /// Starts talking with an agent (after a stare, or a tap).
    func wake(_ a: Agent) {
        if activeId != nil, activeId != a.id { endConversation() }
        activeId = a.id
        stareProgress = 0
        lookAwaySince = nil
        ensurePlaced(a)
        haptics.tap(intensity: 0.9, sharpness: 0.5)
        let firstTime = messages(for: a.id).isEmpty
        let line = firstTime ? (a.greeting.isEmpty ? "Hi, I'm \(a.name). What would you like to know?" : a.greeting) : "I'm listening."
        if firstTime { post(ChatMessage(.agent, line), to: a.id) }
        phase = .greeting
        audio.speak(line, from: a.id, prelude: .chime)
    }

    func endConversation() {
        if isListeningNow { _ = speech.finish() }
        if !speech.keepsInputOpen { speech.shutdown() }
        activeId = nil
        phase = .idle
        transcript = ""
        syncPlacement()
    }

    private var isListeningNow: Bool { phase == .listening }

    private func speakingChanged(_ speaking: Bool) {
        if speaking {
            if phase == .listening, transcript.isEmpty { _ = speech.finish() }
            return
        }
        // The agent finished: your turn.
        if activeId != nil, phase == .greeting || phase == .speaking { startListening() }
    }

    private func startListening() {
        guard let id = activeId else { return }
        phase = .listening
        transcript = ""
        lastHeardAt = Date()
        listenStartedAt = Date()
        speech.begin { [weak self] error in
            guard let self else { return }
            if let error {
                self.post(ChatMessage(.error, error), to: id)
                self.phase = .idle
                return
            }
            guard self.activeId == id, self.phase == .listening else { _ = self.speech.finish(); return }
            self.audio.cue(.listening, from: id)
            self.route = AudioSession.routeDescription
            self.highQualityMic = AudioSession.highQualityMic
        }
    }

    private func heard(_ text: String) {
        guard phase == .listening else { return }
        transcript = text
        lastHeardAt = Date()
    }

    /// Typed message (or a finished utterance).
    func send(_ raw: String, to agentId: UUID? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = agentId ?? activeId, let a = agent(id) else { return }
        if activeId != id { activeId = id; ensurePlaced(a) }
        _ = speech.finish()
        transcript = ""
        post(ChatMessage(.user, text), to: id)
        phase = .thinking
        audio.ping(from: id, high: true)

        // Drop leading agent lines: the model wants the conversation to start with the user.
        var turns = messages(for: id).compactMap { m -> Backend.Turn? in
            switch m.kind {
            case .user: return Backend.Turn(role: "user", content: m.text)
            case .agent: return Backend.Turn(role: "assistant", content: m.text)
            default: return nil
            }
        }
        while turns.first?.role == "assistant" { turns.removeFirst() }

        let placeholder = ChatMessage(.agent, "")
        post(placeholder, to: id)
        let reply = ReplySpeaker(state: self, agentId: id, messageId: placeholder.id)
        Task { @MainActor in
            do {
                let full = try await backend.chat(agentId: id, turns: turns) { piece in
                    DispatchQueue.main.async { MainActor.assumeIsolated { reply.add(piece) } }
                }
                // Queued after every piece, so it runs once they've all been handled.
                DispatchQueue.main.async { MainActor.assumeIsolated { reply.finish(empty: full.isEmpty) } }
            } catch {
                self.updateMessage(placeholder.id, of: id) { $0.kind = .error; $0.text = error.localizedDescription }
                self.phase = .speaking
                self.audio.speak("Sorry, I couldn't answer that.", from: id, prelude: .error)
            }
        }
    }

    /// Called by ReplySpeaker as a streamed reply arrives.
    fileprivate func replyText(_ piece: String, messageId: UUID, agentId: UUID) {
        updateMessage(messageId, of: agentId) { $0.text += piece }
    }

    fileprivate func replySentence(_ sentence: String, agentId: UUID, first: Bool) {
        if phase == .thinking { phase = .speaking }
        audio.speak(sentence, from: agentId, prelude: first ? .chime : nil)
    }

    fileprivate func replyDone(spokeAny: Bool, empty: Bool, messageId: UUID, agentId: UUID) {
        if empty { updateMessage(messageId, of: agentId) { $0.text = "…" } }
        if !spokeAny, activeId == agentId { startListening() }
    }

    /// End index of the next complete sentence in `s` (or everything left when final).
    fileprivate static func sentenceEnd(in s: String, final: Bool) -> String.Index? {
        if final { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s.endIndex }
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if ".!?".contains(c), next < s.endIndex, s[next].isWhitespace, s.distance(from: s.startIndex, to: i) >= 12 {
                return next
            }
            i = next
        }
        return nil
    }

    private func updateMessage(_ messageId: UUID, of agentId: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let j = conversations[agentId]?.firstIndex(where: { $0.id == messageId }) else { return }
        change(&conversations[agentId]![j])
    }

    /// Without full-bandwidth AirPods audio, an open mic means mono: close it before agents speak.
    private func releaseMicForSpeech() -> Bool {
        guard !speech.keepsInputOpen, speech.isInputOpen else { return false }
        speech.shutdown()
        return true
    }

    private func handleGesture(_ g: HeadGesture) {
        lastGesture = g
        // Shake while talking: stop this conversation.
        if g == .shake, activeId != nil { endConversation() }
    }

    // MARK: - Misc

    func recenter() {
        tracker.recenter()
        worldOffset = nil
        calibrateWorld()
    }

    func refreshRoute() {
        route = AudioSession.routeDescription
        highQualityMic = AudioSession.highQualityMic
    }

    /// Demo mode: walk 10 m toward the Find target without moving.
    func demoStep(toward a: Agent, metres: Double = 10) {
        guard let here = location.coordinate, let b = bearing(to: a), let d = distance(to: a) else { return }
        location.simulated = GeoMath.offset(here, metres: min(metres, d), bearing: b)
    }

    func setDemoMode(_ on: Bool) {
        location.simulated = on ? (location.coordinate ?? CLLocationCoordinate2D(latitude: 19.0760, longitude: 72.8777)) : nil
        Task { await refreshNearby(force: true) }
    }
}

/// Speaks a streamed reply sentence by sentence, so the agent starts talking before it's done thinking.
@MainActor
private final class ReplySpeaker {
    private weak var state: MobileState?
    private let agentId: UUID
    private let messageId: UUID
    private var pending = ""
    private var spokeAny = false

    init(state: MobileState, agentId: UUID, messageId: UUID) {
        self.state = state
        self.agentId = agentId
        self.messageId = messageId
    }

    func add(_ piece: String) {
        state?.replyText(piece, messageId: messageId, agentId: agentId)
        pending += piece
        flush(final: false)
    }

    func finish(empty: Bool) {
        flush(final: true)
        state?.replyDone(spokeAny: spokeAny, empty: empty, messageId: messageId, agentId: agentId)
    }

    private func flush(final: Bool) {
        while let end = MobileState.sentenceEnd(in: pending, final: final) {
            let sentence = String(pending[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending = String(pending[end...])
            guard !sentence.isEmpty else { continue }
            state?.replySentence(sentence, agentId: agentId, first: !spokeAny)
            spokeAny = true
        }
    }
}

func normalize360(_ a: Double) -> Double {
    let x = a.truncatingRemainder(dividingBy: 360)
    return x < 0 ? x + 360 : x
}
