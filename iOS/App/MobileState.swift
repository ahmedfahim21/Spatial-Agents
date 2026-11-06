import AVFoundation
import CoreLocation
import Observation
import SwiftUI

enum ConversationPhase: Equatable {
    case idle, greeting, listening, thinking, speaking
}

/// The phone app's brain. Two kinds of agents share one spatial scene:
/// - your agents sit on your left and right, fixed to your head: turn left or right to pick one;
/// - geo-anchored agents sit where they are in the world (compass frame), once you've arrived.
/// Pick one and it lights up; nod (or tap) and it wakes; then you talk hands-free. Shake to end.
@Observable @MainActor
final class MobileState {
    let voices = VoiceRouter()
    let audio: SpatialAudio
    let speech = SpeechInput()
    let location = LocationService()
    let haptics = Haptics()
    private let tracker = HeadTracker()
    /// Picks your left or right agent from which way you turn your head.
    @ObservationIgnored private let turns = TurnPicker()
    /// The side you last turned toward: its agent is picked (bigger on screen), waiting for a
    /// nod or a tap. Not while you're in a conversation; cleared when it ends.
    private(set) var pickedSide: Zone?
    private let backend = Backend.shared
    /// Your account's id (anonymous sign-in), for support and recovery.
    var accountId: String? { backend.userId }

    // MARK: State the UI reads

    var myAgents: [Agent] = []
    var nearby: [Agent] = []
    var backendStatus = ""
    var loading = false

    /// Body-anchored agents are around you.
    var withMe = true { didSet { syncPlacement() } }
    /// What you say is transcribed by Whisper on 0G (more accurate); off = on-device only (instant).
    var whisper = UserDefaults.standard.object(forKey: "whisper") as? Bool ?? true {
        didSet { UserDefaults.standard.set(whisper, forKey: "whisper") }
    }
    var findTargetId: UUID? { didSet { if oldValue != findTargetId { findTargetChanged() } } }
    private(set) var arrived: Set<UUID> = []
    /// How close the agent you're finding is, in steps rather than raw metres (GPS is too
    /// noisy for metres up close). Changes only after holding for 3 s, and each step is left
    /// further out than it was entered, so it doesn't flicker.
    enum Proximity: Equatable {
        case far, close, nearby, here
        var title: String {
            switch self {
            case .far: "Far"
            case .close: "Getting close"
            case .nearby: "Nearby"
            case .here: "Here"
            }
        }
    }
    private(set) var findProximity: Proximity = .far
    /// "Getting closer" / "Getting farther", from the last ~10 s (more reliable than metres).
    private(set) var findTrend: String?
    @ObservationIgnored private var proximityCandidate: (state: Proximity, since: Date)?
    @ObservationIgnored private var proximityFresh = true
    @ObservationIgnored private var findDistances: [(at: Date, d: Double)] = []

    /// How much agents near you say as you walk by (with headphones in).
    enum Announce: String, CaseIterable, Identifiable {
        case voice, sounds, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .voice: "Ask me"
            case .sounds: "Chime only"
            case .off: "Off"
            }
        }
    }
    var announce = Announce(rawValue: UserDefaults.standard.string(forKey: "announce") ?? "") ?? .voice {
        didSet { UserDefaults.standard.set(announce.rawValue, forKey: "announce") }
    }
    /// Walking into a place's radius: Air Agents asks if you want to talk. A double nod is yes
    /// (and, with more than one place around, it asks which one until it hears a name); a
    /// double shake is no.
    struct Invite: Equatable {
        enum Step { case asking, choosing }
        let token: UUID
        var ids: [UUID]
        var step: Step
    }
    private(set) var invite: Invite?
    @ObservationIgnored private var inviteTask: Task<Void, Never>?
    @ObservationIgnored private var inviteAnswer: HeadGesture?
    /// New places around you since the last question.
    @ObservationIgnored private var inviteNeeded = false
    /// Places you said no to: not asked again until you leave and come back.
    @ObservationIgnored private var declinedZones: Set<UUID> = []
    /// When you walked into each place's radius (the newest is "the place you're at").
    @ObservationIgnored private var enteredAt: [UUID: Date] = [:]
    /// Listening for which one, and what's been heard so far.
    @ObservationIgnored private var choosingListen = false
    @ObservationIgnored private var choiceHeard = ""
    @ObservationIgnored private var choiceHeardAt = Date()
    /// The app's own voice, for questions that aren't from any agent.
    private let narratorId = UUID(uuidString: "00000000-0000-0000-0000-0000000A11A5")!

    /// How you nod, shake and turn: learnt in the gesture lesson, or the defaults (a yes is a
    /// double nod, a no a double shake).
    nonisolated static let defaultProfile = GestureProfile(nodSpeed: 35, nodSize: 10, nodSwings: 3, nodRatio: 1.0,
                                               shakeSpeed: 70, shakeSize: 15, shakeSwings: 3, window: 1.6,
                                               turnSize: 15, turnTime: 0.8)
    var gestureProfile: GestureProfile = {
        guard let d = UserDefaults.standard.data(forKey: "gestureProfile"),
              let p = try? JSONDecoder().decode(GestureProfile.self, from: d) else { return MobileState.defaultProfile }
        return p
    }() {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(gestureProfile), forKey: "gestureProfile")
            gesturesLearned = true
            applyGestures()
        }
    }
    private(set) var gesturesLearned = UserDefaults.standard.data(forKey: "gestureProfile") != nil
    /// 0.5 (firm) … 2 (light): scales how big and quick every gesture has to be.
    var gestureSensitivity = UserDefaults.standard.object(forKey: "gestureSensitivity") as? Double ?? 1 {
        didSet {
            UserDefaults.standard.set(gestureSensitivity, forKey: "gestureSensitivity")
            applyGestures()
        }
    }
    /// The gesture lesson is running: gestures are recorded, not acted on.
    var training = false
    @ObservationIgnored private var recording: [MotionSample]?
    /// What the head just did, for the lesson's try-it step.
    private(set) var lastMove: (name: String, at: Date)?

    func resetGestures() {
        UserDefaults.standard.removeObject(forKey: "gestureProfile")
        gestureProfile = Self.defaultProfile
        UserDefaults.standard.removeObject(forKey: "gestureProfile")
        gesturesLearned = false
    }

    private func applyGestures() {
        let s = max(gestureSensitivity, 0.1)
        tracker.profile = gestureProfile
        tracker.sensitivity = s
        turns.size = gestureProfile.turnSize / s
        turns.within = gestureProfile.turnTime
    }

    /// Records head motion for a while (the gesture lesson).
    func recordMotion(seconds: Double) async -> [MotionSample] {
        recording = []
        try? await Task.sleep(for: .seconds(seconds))
        defer { recording = nil }
        return recording ?? []
    }
    @ObservationIgnored private var headphonesIn = false

    /// Shops' menus, fetched when you arrive at one (shown over it on the map).
    private(set) var menus: [UUID: [CatalogItem]] = [:]

    private(set) var focusedId: UUID?
    /// Raw head pitch, degrees. Rounded to whole degrees and written only when it changes, so
    /// screens redraw as fast as you actually move rather than at the sensor rate.
    private(set) var headPitchRaw: Double = 0
    /// Where your head points in the world, degrees from true north (rounded, for views).
    private(set) var headWorld: Double?
    /// Agents whose conversation just ended (eyes closed) or failed (worried).
    private(set) var asleep: Set<UUID> = []
    private(set) var failing: Set<UUID> = []
    /// Which tab is showing. Looking at agents only does anything on the screens that show them.
    enum Screen { case explore, withMe, agents, settings }
    var screen: Screen = .explore { didSet { if oldValue != screen { updateFocus() } } }
    private var lookingEnabled: Bool { screen == .explore || screen == .withMe }
    private(set) var activeId: UUID?
    private(set) var phase: ConversationPhase = .idle
    private(set) var transcript = ""
    var conversations: [UUID: [ChatMessage]] = [:] { didSet { saveConversationsSoon() } }
    /// What each tool call did (by the tool message's id), so later turns know what was done.
    @ObservationIgnored private var toolNotes: [UUID: String] = [:]
    /// Orders placed in conversations, by the id of their `.order` message.
    private(set) var orders: [UUID: OrderCard] = [:] { didSet { saveConversationsSoon() } }
    @ObservationIgnored private var conversationSave: Task<Void, Never>?
    /// Runs your agents' tool calls on this phone (calendar, Health, maps…).
    @ObservationIgnored private(set) lazy var phoneTools = PhoneTools { [weak self] in
        self?.location.coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
    }
    /// The agent said something like "Let me check." and is waiting on a tool: when that
    /// line finishes, keep thinking rather than start listening.
    @ObservationIgnored private var awaitingTools = false
    /// A reply is still arriving: more sentences may come, so a pause in speech isn't the end.
    @ObservationIgnored private var replyArriving = false
    /// You're typing to the agent: it doesn't listen after replying until you tap the mic.
    private(set) var typingMode = false
    /// Your World ID verification (a verified human), once you've done it.
    private(set) var worldIdentity: WorldIdentity?
    @ObservationIgnored private let worldAuth = WorldAuth()
    /// The order card of each agent's reply in flight.
    @ObservationIgnored private var liveOrder: [UUID: UUID] = [:]

    /// Where each body-anchored agent sits around you right now.
    private(set) var zones: [UUID: Zone] = [:]
    /// Your usual pair (outside any time of day), saved as "zones".
    @ObservationIgnored private var defaultZones: [UUID: Zone] = [:]
    /// Pairs by time of day.
    var lineups: [Lineup] = LineupStore.load() { didSet { LineupStore.save(lineups) } }
    /// The time of day in effect now, if any.
    private(set) var activeLineupId: UUID?
    var activeLineup: Lineup? { lineups.first { $0.id == activeLineupId } }
    @ObservationIgnored private var lastLineupCheck = Date.distantPast
    /// The user has arranged their agents.
    private(set) var calibrated = UserDefaults.standard.bool(forKey: "calibrated")
    /// Head pitch when looking straight ahead (AirPods sit differently on everyone).
    private(set) var pitchZero = UserDefaults.standard.double(forKey: "pitchZero")
    /// Head pitch relative to straight ahead.
    var headPitch: Double { headPitchRaw - pitchZero }

    /// The kind of agent Create starts with (other screens can preset it).
    var createFlavor: AgentFlavor = .withMe
    /// The Create form is open (a sheet over Agents).
    var creating = false

    /// Opens Create, ready to make this kind of agent.
    func startCreating(_ flavor: AgentFlavor) {
        createFlavor = flavor
        screen = .agents
        creating = true
    }

    /// While arranging agents, looking at one shouldn't wake it.
    var arranging = false

    var trackingStatus = "Starting…"
    private(set) var hasHeadData = false
    var lastGesture: HeadGesture?
    var route = ""
    var highQualityMic = false
    var voiceStatus = ""

    // MARK: Head frames

    /// Head yaw in the tracker's fixed frame.
    @ObservationIgnored private var yawFixed: Double = 0
    /// Head pitch, degrees (+ = up).
    @ObservationIgnored private var pitchRaw: Double = 0
    /// Compass heading of the tracker's fixed-frame zero; nil until calibrated.
    @ObservationIgnored private var worldOffset: Double?
    @ObservationIgnored private var lastHeadAt = Date.distantPast
    @ObservationIgnored private var lastYawLog = Date.distantPast

    /// Exact head direction in the world.
    private var exactWorld: Double? {
        if hasHeadData, let o = worldOffset { return normalize360(o + yawFixed) }
        return location.heading   // no AirPods: the phone is the pointer
    }

    /// Hands the current pose to views, only where it changed by a degree or more.
    private func publishPose() {
        let pitch = pitchRaw.rounded(), world = exactWorld?.rounded()
        if pitch != headPitchRaw { headPitchRaw = pitch }
        if world != headWorld { headWorld = world }
    }

    // MARK: Placement

    @ObservationIgnored private var placed: Set<UUID> = []
    /// Body agents' fixed slots around you.
    private var bodySlots: [UUID: Zone] = [:]
    /// Geo agents' bearings, frozen when close or when GPS is poor so they don't jitter.
    private var lockedBearing: [UUID: Double] = [:]
    @ObservationIgnored private var lastHeardAt = Date()
    @ObservationIgnored private var listenStartedAt = Date()
    @ObservationIgnored private var lastBeacon = Date.distantPast
    @ObservationIgnored private var lastWarmUp = Date.distantPast
    @ObservationIgnored private var lastThinkingPulse = Date.distantPast
    @ObservationIgnored private var lastNearbyFetch: (at: Date, where: CLLocationCoordinate2D)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    init() {
        // Play only until start(): a recording session would ask for the mic before
        // onboarding has explained why.
        AudioSession.configurePlaybackOnly()
        audio = SpatialAudio(voices: voices)
        audio.headYaw = 0   // positions are computed here, already head-relative
        voices.primary = ServerVoice()
        voices.onStatus = { [weak self] s in self?.voiceStatus = s }

        (conversations, orders, toolNotes) = ConversationStore.load()
        if let saved = UserDefaults.standard.dictionary(forKey: "zones") as? [String: String] {
            defaultZones = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in
                guard let id = UUID(uuidString: k), let z = Zone(rawValue: v) else { return nil }
                return (id, z)
            })
            zones = defaultZones
        }
        activeLineupId = currentLineupId()
        // Only head movement counts, never where it points: there's no forward to set or drift.
        tracker.followMe = false
        tracker.onStatus = { [weak self] s in
            print("Agentsphere: tracking status: \(s)")
            self?.trackingStatus = s
        }
        tracker.onFixedYaw = { [weak self] y in self?.headMoved(yaw: y) }
        tracker.onPitch = { [weak self] p in self?.pitchRaw = p }
        tracker.onGesture = { [weak self] g in self?.handleGesture(g) }
        tracker.onSample = { [weak self] t, y, p in self?.recording?.append(MotionSample(t: t, yaw: y, pitch: p)) }
        applyGestures()
        tracker.onDebug = { print("Agentsphere: \($0)") }
        tracker.isEngaged = { [weak self] in
            guard let self else { return false }
            return self.activeId != nil && self.phase != .idle
        }
        speech.onPartial = { [weak self] t in self?.heard(t) }
        audio.onSpeakingChanged = { [weak self] speaking in self?.speakingChanged(speaking) }
        audio.beforeSpeaking = { [weak self] in self?.releaseMicForSpeech() ?? false }

        location.onMove = { [weak self] in self?.locationChanged() }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRoute() }
        }
        location.onHeading = { [weak self] in self?.calibrateWorld(); self?.updateScene() }

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        refreshRoute()
    }

    /// Starts sensors and loads agents. Called once onboarding is done, so permission
    /// prompts appear in context rather than all at once on first launch.
    func start() {
        guard !started else { return }
        started = true
        AudioSession.configure()
        refreshRoute()
        tracker.start()
        audio.register(id: narratorId, azimuth: 0, voiceIndex: 0)
        location.start()
        Task { await refreshMine() }
        Task { await refreshIdentity() }
    }

    /// For onboarding: ask for motion access by starting AirPods head tracking.
    func startHeadTracking() { tracker.start() }

    // MARK: - Faces

    /// How an agent's face should look right now.
    func mood(for a: Agent) -> BotMood {
        if failing.contains(a.id) { return .error }
        if activeId == a.id {
            switch phase {
            case .greeting: return .awake
            case .speaking: return .speaking
            case .listening: return .listening
            case .thinking: return .thinking
            case .idle: return .awake
            }
        }
        if focusedId == a.id { return .focused }
        if asleep.contains(a.id) { return .ended }
        if arrived.contains(a.id) { return .arrived }
        return .idle
    }

    /// Where an agent's eyes should look so they face you (-1 left … 1 right).
    func look(for a: Agent) -> Double {
        guard let rel = relativeAngle(a.id) else { return 0 }
        return -max(-1, min(1, sin(rel * .pi / 180)))
    }

    // MARK: - Agents

    var bodyAgents: [Agent] { myAgents.filter { !$0.isGeo } }

    func agent(_ id: UUID?) -> Agent? {
        guard let id else { return nil }
        return myAgents.first { $0.id == id } ?? nearby.first { $0.id == id }
    }

    /// Sample data only (UI previews): never talk to the server.
    @ObservationIgnored var offline = false

    func refreshMine() async {
        guard Config.isConfigured, !offline else { return }
        do {
            myAgents = try await backend.myAgents()
            backendStatus = ""
            syncPlacement()
            print("Agentsphere: my agents: \(myAgents.map { "\($0.name) [\($0.isGeo ? "geo" : "body")\(zones[$0.id].map { ", " + $0.name } ?? "")]" })")
        } catch {
            backendStatus = error.localizedDescription
            print("Agentsphere: loading my agents failed: \(error.localizedDescription)")
        }
    }

    func refreshNearby(force: Bool = false) async {
        guard Config.isConfigured, !offline, let here = location.coordinate else { return }
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
        var a = try await backend.create(new)
        myAgents.insert(a, at: 0)
        if a.isGeo {
            // Show it straight away; the server's list catches up in the background.
            a.isMine = true
            nearby.append(a)
            updateArrivals()
            Task { await refreshNearby(force: true) }
        }
        syncPlacement()
        return a
    }

    /// Agents you've placed in the world, public and private, at any distance.
    var placedAgents: [Agent] { myAgents.filter(\.isGeo) }

    func owns(_ id: UUID) -> Bool { myAgents.contains { $0.id == id } }

    /// Saves changes to one of your agents and, for public places, its menu
    /// (`menu` nil = leave payments as they are; empty = stop taking payments).
    func update(_ id: UUID, _ changes: Backend.AgentChanges, menu: [CatalogItem]?) async throws {
        var updated = try await backend.update(id, changes)
        if let menu, updated.isPublic, updated.isGeo {
            let wasPaid = updated.pricing == "paid"
            if !menu.isEmpty || wasPaid {
                _ = try await backend.saveCatalog(agentId: id, items: menu)
                updated.pricing = menu.isEmpty ? "free" : "paid"
            }
        }
        if let i = myAgents.firstIndex(where: { $0.id == id }) {
            if updated.walletAddress == nil { updated.walletAddress = myAgents[i].walletAddress }
            myAgents[i] = updated
        }
        if let i = nearby.firstIndex(where: { $0.id == id }) {
            // Keep what only nearby search knows.
            updated.isMine = true
            updated.distanceM = nearby[i].distanceM
            updated.verified = nearby[i].verified
            nearby[i] = updated
        }
        updateArrivals()
        syncPlacement()
        // The shop's wallet is assigned on the server: pick it up.
        if menu?.isEmpty == false { Task { await refreshMine() } }
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

    /// A distance as precise as the fix allows ("Nearby" within GPS error).
    func distanceText(_ d: Double) -> String {
        GeoMath.describe(distance: d, accuracy: location.simulated != nil ? 0 : location.accuracy)
    }

    /// How wide the Find arrow's glow should be: wider when position or heading is unsure.
    func arrowSpread(to a: Agent) -> Double {
        guard let d = distance(to: a) else { return 90 }
        let position = atan2(min(location.accuracy, 60), max(d, 1)) * 180 / .pi
        let heading = location.headingAccuracy.isFinite ? location.headingAccuracy : 30
        return min(90, max(35, 25 + position + heading))
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
                enteredAt[a.id] = nil
                declinedZones.remove(a.id)
                if activeId == a.id { endConversation() }
                if var inv = invite, inv.ids.contains(a.id) {
                    inv.ids.removeAll { $0 == a.id }
                    if inv.ids.isEmpty { endInvite(declined: false) } else { invite = inv }
                }
            }
        }
        if now != arrived { arrived = now; syncPlacement() }
        updateFindFeedback()
    }

    private func didArrive(at a: Agent) {
        haptics.arrived()
        if a.pricing == "paid" { Task { await loadMenu(a.id) } }
        if findTargetId == a.id { haptics.distance = nil }
        ensurePlaced(a)
        audio.setGain(id: a.id, gain: 1)
        audio.setCloseness(id: a.id, 1)
        enteredAt[a.id] = Date()
        print("Agentsphere: entered \(a.name)'s zone")
        switch announce {
        case .voice: inviteNeeded = true
        case .sounds: audio.cue(.chime, from: a.id)
        case .off: break
        }
    }

    /// Places whose radius you're in, the one you walked into last first.
    private var zonesHere: [Agent] {
        nearby.filter { arrived.contains($0.id) }
            .sorted { (enteredAt[$0.id] ?? .distantPast) > (enteredAt[$1.id] ?? .distantPast) }
    }

    /// Find mode: haptics and a beacon, quicker as you near it.
    private func findTargetChanged() {
        haptics.distance = nil
        proximityFresh = true
        proximityCandidate = nil
        findDistances = []
        findTrend = nil
        findProximity = findTargetId.map { arrived.contains($0) } == true ? .here : .far
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
            findProximity = .here
            return
        }
        let beyond = max(0, d - arrivalRadius(for: a))
        haptics.distance = beyond
        updateProximity(beyond: beyond)
        updateTrend(d)
    }

    private func updateProximity(beyond b: Double) {
        let current = findProximity
        // Entered at 20 m / 120 m beyond arrival; left at 1.5x that.
        let nearbyLimit: Double = current == .nearby ? 30 : 20
        let closeLimit: Double = current == .close || current == .nearby ? 180 : 120
        let raw: Proximity = b < nearbyLimit ? .nearby : b < closeLimit ? .close : .far
        if proximityFresh || current == .here {
            proximityFresh = false
            findProximity = raw
            proximityCandidate = nil
            return
        }
        guard raw != current else { proximityCandidate = nil; return }
        if let c = proximityCandidate, c.state == raw {
            if Date().timeIntervalSince(c.since) >= 3 {
                if raw == .nearby { haptics.light() }
                findProximity = raw
                proximityCandidate = nil
            }
        } else {
            proximityCandidate = (raw, Date())
        }
    }

    private func updateTrend(_ d: Double) {
        let now = Date()
        findDistances.append((now, d))
        findDistances.removeAll { now.timeIntervalSince($0.at) > 12 }
        guard let oldest = findDistances.first, now.timeIntervalSince(oldest.at) >= 8, !location.stationary else {
            findTrend = nil
            return
        }
        let change = d - oldest.d
        let next: String? = change < -4 ? "Getting closer" : change > 4 ? "Getting farther" : nil
        if next != findTrend { findTrend = next }
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
        let lookingAtPhone = pitchRaw < -12
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
        assignZones()
        var want = Set<UUID>()
        // Body agents are heard only from a window.
        if withMe { for a in bodyAgents where zones[a.id] != nil { want.insert(a.id) } }
        want.formUnion(arrived)
        if let f = findTargetId { want.insert(f) }
        if let active = activeId { want.insert(active) }

        for id in placed.subtracting(want) {
            audio.remove(id: id)
            placed.remove(id)
        }
        for id in want.subtracting(placed) { if let a = agent(id) { ensurePlaced(a) } }

        bodySlots = zones.filter { id, _ in bodyAgents.contains { $0.id == id } }
        updateScene()
    }

    // MARK: - Zones

    /// Windows you emptied on purpose: new agents don't fill them.
    private var emptiedWindows: Set<Zone> = Set((UserDefaults.standard.stringArray(forKey: "emptiedWindows") ?? []).compactMap(Zone.init))

    /// A time of day sets the windows exactly. Otherwise your usual pair: each window keeps
    /// its agent, and a free window (that you didn't empty) takes the next agent without one.
    private func assignZones() {
        let ids = Set(bodyAgents.map(\.id))
        if let l = activeLineup {
            var next: [UUID: Zone] = [:]
            for z in Zone.allCases { if let id = l[z], ids.contains(id) { next[id] = z } }
            if next != zones { zones = next }
            return
        }
        var next = defaultZones.filter { ids.contains($0.key) }
        for a in bodyAgents.reversed() where next[a.id] == nil {
            let used = Set(next.values)
            if let free = Zone.fillOrder.first(where: { !used.contains($0) && !emptiedWindows.contains($0) }) { next[a.id] = free }
        }
        if next != defaultZones { defaultZones = next; saveZones() }
        if next != zones { zones = next }
    }

    /// Puts an agent in a window (nil = empty it). Whoever was there leaves; if the agent
    /// was in the other window, the two swap. During a time of day, this changes that time's pair.
    func setWindow(_ zone: Zone, to id: UUID?) {
        if let i = lineups.firstIndex(where: { $0.id == activeLineupId }) {
            var l = lineups[i]
            let other: Zone = zone == .left ? .right : .left
            if let id, l[other] == id { l[other] = l[zone] }
            l[zone] = id
            lineups[i] = l
            syncPlacement()
            return
        }
        var next = defaultZones
        let occupant = next.first(where: { $0.value == zone })?.key
        if let id {
            if let old = next[id], let occupant, occupant != id { next[occupant] = old } else if let occupant { next[occupant] = nil }
            next[id] = zone
            emptiedWindows.remove(zone)
        } else {
            if let occupant { next[occupant] = nil }
            emptiedWindows.insert(zone)
        }
        UserDefaults.standard.set(emptiedWindows.map(\.rawValue), forKey: "emptiedWindows")
        defaultZones = next
        saveZones()
        syncPlacement()
    }

    /// Takes an agent out of its window.
    func removeFromWindow(_ id: UUID) {
        if let zone = zones[id] { setWindow(zone, to: nil) }
    }

    func agent(in zone: Zone) -> Agent? {
        guard let id = zones.first(where: { $0.value == zone })?.key else { return nil }
        return bodyAgents.first { $0.id == id }
    }

    /// Body agents not in a window.
    var unzonedAgents: [Agent] { bodyAgents.filter { zones[$0.id] == nil } }

    private func saveZones() {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: defaultZones.map { ($0.key.uuidString, $0.value.rawValue) }), forKey: "zones")
    }

    // MARK: - Times of day

    private func currentLineupId(at date: Date = Date()) -> UUID? {
        let m = Lineup.minute(of: date)
        return lineups.first { $0.contains(minute: m) }?.id
    }

    /// Switches pairs when a time of day starts or ends (not mid-conversation), and has the
    /// new pair say hello from their sides.
    private func checkLineup(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastLineupCheck) > 15 else { return }
        lastLineupCheck = Date()
        let next = currentLineupId()
        guard next != activeLineupId else { return }
        guard activeId == nil || force else { return }
        activeLineupId = next
        print("Agentsphere: time of day → \(activeLineup?.name ?? "usual pair")")
        syncPlacement()
        guard !force else { return }
        haptics.light()
        introducePair(activeLineup?.name)
    }

    /// "Evening. I'm Coach, on your left." then "And I'm Journal, on your right."
    private func introducePair(_ name: String?) {
        guard announce == .voice, headphonesIn, withMe else { return }
        let left = agent(in: .left), right = agent(in: .right)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let left {
                self.audio.speak("\(name.map { "\($0). " } ?? "")I'm \(left.name), on your left.", from: left.id, prelude: .chime)
                try? await Task.sleep(for: .seconds(0.6))
                while self.audio.isSpeaking { try? await Task.sleep(for: .seconds(0.2)) }
            }
            if let right, self.activeId == nil {
                self.audio.speak("\(left == nil ? name.map { "\($0). " } ?? "" : "And ")I'm \(right.name), on your right.", from: right.id, prelude: left == nil ? .chime : nil)
            }
        }
    }

    func saveLineup(_ l: Lineup) {
        if let i = lineups.firstIndex(where: { $0.id == l.id }) { lineups[i] = l } else { lineups.append(l) }
        refreshLineup()
    }

    func deleteLineup(_ id: UUID) {
        lineups.removeAll { $0.id == id }
        refreshLineup()
    }

    func deleteLineups(at offsets: IndexSet) {
        lineups.remove(atOffsets: offsets)
        refreshLineup()
    }

    /// After an edit: apply it now, quietly.
    private func refreshLineup() {
        activeLineupId = currentLineupId()
        syncPlacement()
    }

    func finishSetup() {
        calibrated = true
        UserDefaults.standard.set(true, forKey: "calibrated")
    }

    /// The agent says where it is, from where it is.
    func preview(_ id: UUID) {
        guard let a = agent(id), let z = zones[id] else { return }
        ensurePlaced(a)
        updateScene()
        audio.speak("I'm \(a.name), \(z.spoken).", from: id, prelude: .chime)
    }

    /// Angle of an agent relative to where your head points (0 = straight ahead, + = right).
    /// Your agents are fixed to your head: the left one is always on your left. Agents out in
    /// the world come from the compass. For views: from the published (whole-degree) pose.
    func relativeAngle(_ id: UUID) -> Double? { angle(id, world: headWorld) }

    /// For audio and focus: the exact pose.

    private func angle(_ id: UUID, world: Double?) -> Double? {
        if let zone = bodySlots[id], withMe { return zone.azimuth }
        guard let a = agent(id), a.isGeo, let b = bearing(to: a), let world else { return nil }
        return normalizeAngle(b - world)
    }

    /// Agents you can look at and wake right now.
    var talkable: [Agent] {
        (withMe ? bodyAgents.filter { zones[$0.id] != nil } : []) + nearby.filter { arrived.contains($0.id) }
    }

    private func updateScene() {
        // Your agents sit left and right of you. Agents out in the world have no direction:
        // their voices play straight, as a plain voice.
        for id in placed {
            if let zone = bodySlots[id], withMe {
                audio.setDirection(id: id, azimuth: zone.azimuth, elevation: zone.elevation)
            } else {
                audio.setDirection(id: id, azimuth: 0, elevation: 0)
            }
        }
        updateFocus()
        publishPose()
    }

    private func updateFocus() {
        // Your agents: the side you last turned toward (needs AirPods; a tap works without).
        // Places out in the world aren't picked by looking: you're asked when you walk in.
        // On Create or Settings, your attention is on the phone: no pings, no waking agents.
        let pool = (lookingEnabled || arranging ? talkable : talkable.filter { $0.id == activeId })
            .filter { hasHeadData && bodySlots[$0.id] != nil }
        let next = pickedSide.flatMap { side in pool.first { bodySlots[$0.id] == side } }?.id
        if next != focusedId {
            print("Agentsphere: focus → \(agent(next)?.name ?? "nobody")")
            focusedId = next
            if let n = next, n != activeId {
                audio.ping(from: n, high: false)
                haptics.tap(intensity: 0.4, sharpness: 0.3)
                // You're about to talk to someone: make sure the server is awake.
                if Date().timeIntervalSince(lastWarmUp) > 60, Config.isConfigured {
                    lastWarmUp = Date()
                    backend.warmUp()
                }
            }
        }
    }

    private func tick() {
        if hasHeadData, Date().timeIntervalSince(lastHeadAt) > 3 {
            hasHeadData = false
            trackingStatus = "AirPods head tracking paused. Put your AirPods in to look around."
        }
        if !hasHeadData { updateScene() }   // the phone's heading still turns the Find arrow
        beaconTick()
        inviteTick()
        checkLineup()
        // A no means something only in a conversation or a question: otherwise a big turn
        // could pass for one.
        tracker.detectShakes = activeId != nil || invite != nil || training

        // Conversation housekeeping.
        guard let active = activeId else { return }
        // A quiet pulse from the agent while it thinks, so the wait never feels dead.
        if phase == .thinking, Date().timeIntervalSince(lastThinkingPulse) > 1.3 {
            lastThinkingPulse = Date()
            audio.cue(.thinking, from: active)
        }
        if phase == .listening {
            // A word or two and a pause ("Can you…") usually means you're still thinking.
            let words = transcript.split(separator: " ").count
            if !transcript.isEmpty, Date().timeIntervalSince(lastHeardAt) > (words <= 2 ? 2.6 : 1.3) {
                finishUtterance()
            } else if transcript.isEmpty, Date().timeIntervalSince(listenStartedAt) > 40 {
                endConversation()
            }
        }
    }

    // MARK: - Conversation

    func messages(for id: UUID) -> [ChatMessage] { conversations[id] ?? [] }

    /// Writes conversations to disk a moment after they stop changing (a streaming reply
    /// changes them many times a second). Sample data stays in memory.
    private func saveConversationsSoon() {
        guard !offline else { return }
        conversationSave?.cancel()
        conversationSave = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            ConversationStore.save(self.conversations, orders: self.orders, toolNotes: self.toolNotes)
        }
    }

    private func post(_ m: ChatMessage, to id: UUID) {
        conversations[id, default: []].append(m)
    }

    /// You've said something to this agent (more than its greeting is there).
    func hasChat(_ id: UUID) -> Bool { messages(for: id).contains { $0.kind == .user } }

    /// Agents you've talked to.
    var chattedAgents: Int { conversations.keys.filter(hasChat).count }

    private func greetingLine(_ a: Agent) -> String {
        a.greeting.isEmpty ? "Hi, I'm \(a.name). What would you like to know?" : a.greeting
    }

    /// Clears a conversation back to just the agent's greeting (orders in it go too).
    func clearChat(_ id: UUID) {
        for m in messages(for: id) where m.kind == .order { orders[m.id] = nil }
        if activeId == id { transcript = "" }
        conversations[id] = agent(id).map { [ChatMessage(.agent, greetingLine($0))] }
    }

    func clearAllChats() {
        for id in Array(conversations.keys) { clearChat(id) }
    }

    private func insert(_ m: ChatMessage, before messageId: UUID, of id: UUID) {
        guard let i = conversations[id]?.firstIndex(where: { $0.id == messageId }) else { return post(m, to: id) }
        conversations[id]!.insert(m, at: i)
    }

    /// Tools an agent may use on this phone: only your own agents that aren't public.
    func toolAccess(_ a: Agent) -> Set<AgentTool> {
        guard !offline, !a.isPublic, owns(a.id) else { return [] }
        return ToolAccess.tools(for: a.id)
    }

    /// Starts talking with an agent (after a nod, or a tap).
    func wake(_ a: Agent) {
        print("Agentsphere: wake \(a.name)")
        if invite != nil { endInvite(declined: false, keepMic: true) }
        if activeId != nil, activeId != a.id { endConversation() }
        activeId = a.id
        // The agent you're talking to stays picked, however you woke it (nod, tap, wake word).
        pickedSide = withMe ? zones[a.id] : nil
        updateFocus()
        asleep.remove(a.id)
        failing.remove(a.id)
        ensurePlaced(a)
        haptics.tap(intensity: 0.9, sharpness: 0.5)
        let history = messages(for: a.id)
        // Nothing said yet (new, or cleared back to its greeting): greet.
        let fresh = !history.contains { $0.kind == .user }
        // Coming back after a while: say so, then carry on from the same conversation.
        let away = history.last.map { Date().timeIntervalSince($0.date) > 20 * 60 } ?? false
        let line = fresh ? greetingLine(a) : away ? "Welcome back. Where were we?" : "I'm listening."
        if fresh, history.last?.text != line { post(ChatMessage(.agent, line), to: a.id) }
        phase = .greeting
        audio.speak(line, from: a.id, prelude: .chime)
    }

    func endConversation(file: String = #fileID, line: Int = #line) {
        if let id = activeId { print("Agentsphere: ended \(agent(id)?.name ?? "conversation") (\(file):\(line))") }
        typingMode = false
        if isListeningNow { _ = speech.finish() }
        if !speech.keepsInputOpen { speech.shutdown() }
        if let id = activeId {
            audio.silence(id: id)
            haptics.ended()
            asleep.insert(id)
            // Asleep for a while, then back to normal.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?.activeId != id { self?.asleep.remove(id) }
            }
        }
        activeId = nil
        phase = .idle
        transcript = ""
        pickedSide = nil
        syncPlacement()
    }

    private var isListeningNow: Bool { phase == .listening }

    private func speakingChanged(_ speaking: Bool) {
        if speaking {
            // An agent talking over an idle mic: stop listening for now, and pick it up again
            // when it's done (as .speaking, so the end of speech restarts listening).
            if phase == .listening, transcript.isEmpty { _ = speech.finish(); phase = .speaking }
            return
        }
        if awaitingTools, phase == .speaking { phase = .thinking; return }
        // More of the reply is still on its way.
        if replyArriving { return }
        // The agent finished: your turn.
        if activeId != nil, phase == .greeting || phase == .speaking { startListening() }
    }

    private func startListening() {
        guard let id = activeId else { return }
        if typingMode {
            phase = .idle
            return
        }
        print("Agentsphere: listening")
        phase = .listening
        transcript = ""
        lastHeardAt = Date()
        listenStartedAt = Date()
        speech.recordsAudio = whisper && Config.isConfigured && !offline
        speech.begin { [weak self] error in
            guard let self else { return }
            if let error {
                print("Agentsphere: listening failed: \(error)")
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
        if choosingListen {
            choiceHeard = text
            choiceHeardAt = Date()
            return
        }
        guard phase == .listening else { return }
        transcript = text
        lastHeardAt = Date()
        // "Bye bye", "goodbye", "never mind": end now, not after the pause and transcription.
        if Self.isGoodbye(text, instant: true), let id = activeId { deliver(text, to: id) }
    }

    /// What you said: a goodbye ends the conversation; anything else goes to the agent.
    private func deliver(_ text: String, to id: UUID) {
        guard Self.isGoodbye(text) else { return send(text, to: id) }
        post(ChatMessage(.user, text.trimmingCharacters(in: .whitespacesAndNewlines)), to: id)
        endConversation()
        audio.speak("Talk soon.", from: id, prelude: nil)
    }

    /// Kill words: the whole utterance, so a real request that happens to contain "bye" or
    /// "stop" still goes through. `instant`: only phrases safe to act on while you may still
    /// be talking (a lone "stop" might become "stop the timer").
    static func isGoodbye(_ text: String, instant: Bool = false) -> Bool {
        let t = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[^a-z' ]", with: "", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        let now: Set<String> = [
            "bye bye", "byebye", "goodbye", "good bye", "bye for now", "see you", "see ya", "seeya", "see you later",
            "talk to you later", "talk later", "that's all", "thats all", "i'm done", "im done", "never mind",
            "nevermind", "stop talking", "shut up", "be quiet", "stop listening", "end chat", "end the chat",
        ]
        let afterPause: Set<String> = [
            "bye", "cya", "ok bye", "okay bye", "thanks bye", "thank you bye", "bye now", "that's it", "thats it",
            "thanks i'm done", "thanks im done", "thank you that's all", "thanks that's all", "stop", "cancel",
            "quiet", "good night", "goodnight",
        ]
        return now.contains(t) || (!instant && afterPause.contains(t))
    }

    /// You stopped talking. On-device recognition showed your words as you spoke and noticed
    /// the pause; Whisper on 0G has the final say on what you said, with the on-device text as
    /// the fallback if it's slow or fails. A kill word doesn't wait for Whisper.
    private func finishUtterance() {
        guard let id = activeId else { return }
        let (onDevice, wav) = speech.finishWithAudio()
        let heard = onDevice.isEmpty ? transcript : onDevice
        haptics.light()
        guard let wav, !Self.isGoodbye(heard) else { deliver(heard, to: id); return }
        phase = .thinking
        let isPrivate = agent(id)?.privateInference == true
        Task { @MainActor [weak self] in
            let started = Date()
            let whisper = await self?.backend.transcribe(wav, timeout: 6, privateInference: isPrivate)
            guard let self, self.activeId == id, self.phase == .thinking else { return }
            let text = whisper?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            print("Agentsphere: whisper (\(Int(Date().timeIntervalSince(started) * 1000)) ms): \(text.isEmpty ? "–" : text) | on-device: \(heard)")
            self.deliver(text.isEmpty ? heard : text, to: id)
        }
    }

    /// Typed message (or a finished utterance).
    func send(_ raw: String, to agentId: UUID? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = agentId ?? activeId, let a = agent(id) else { return }
        print("Agentsphere: send to \(a.name): \(text)")
        if activeId != id { activeId = id; ensurePlaced(a) }
        _ = speech.finish()
        transcript = ""
        post(ChatMessage(.user, text), to: id)
        failing.remove(id)
        phase = .thinking
        audio.ping(from: id, high: true)

        // Drop leading agent lines: the model wants the conversation to start with the user.
        var turns: [Backend.Turn] = []
        var done: [String] = []
        for m in messages(for: id) {
            switch m.kind {
            case .user: turns.append(Backend.Turn(role: "user", content: m.text)); done = []
            case .tool: if let note = toolNotes[m.id] { done.append(note) }
            case .agent:
                // What its tools did in that turn, so it doesn't redo (or doubt) them.
                let record = done.isEmpty ? "" : " [Done on the phone: \(done.joined(separator: "; "))]"
                turns.append(Backend.Turn(role: "assistant", content: m.text + record))
                done = []
            case .order:
                // So the agent knows what was already bought (and doesn't order it again).
                if let card = orders[m.id], let last = turns.last, last.role == "assistant" {
                    turns[turns.count - 1] = Backend.Turn(role: "assistant", content: last.content + " (Order: \(card.title), \(Money.usd(card.amount)), \(card.outcome).)")
                }
            default: break
            }
        }
        // The recent part of a long conversation is what matters to the reply.
        if turns.count > 40 { turns.removeFirst(turns.count - 40) }
        while turns.first?.role == "assistant" { turns.removeFirst() }

        let placeholder = ChatMessage(.agent, "")
        post(placeholder, to: id)
        replyArriving = true
        let reply = ReplySpeaker(state: self, agentId: id, messageId: placeholder.id)
        let allowed = toolAccess(a)
        let client = ["now": PhoneTools.now, "timezone": TimeZone.current.identifier]
        var history: [[String: Any]] = turns.map { ["role": $0.role, "content": $0.content] }
        Task { @MainActor in
            do {
                var full = ""
                // Each round may ask for tools; the last round offers none, so it has to answer.
                for round in 0..<4 {
                    let final = round == 3
                    let result = try await backend.chat(
                        agentId: id, messages: history, tools: allowed.map(\.rawValue), final: final, client: client,
                        onText: { piece in
                            DispatchQueue.main.async { MainActor.assumeIsolated { reply.add(piece) } }
                        }, onOrder: { update in
                            DispatchQueue.main.async { MainActor.assumeIsolated { self.orderUpdate(update, agentId: id) } }
                        })
                    full += result.text
                    guard !result.toolCalls.isEmpty, !final else { break }
                    // Say "Let me check." now, while the tools run.
                    awaitingTools = true
                    if !result.text.isEmpty {
                        DispatchQueue.main.async { MainActor.assumeIsolated { reply.add(" ") } }
                    }
                    history.append([
                        "role": "assistant", "content": result.text,
                        "tool_calls": result.toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] },
                    ])
                    for call in result.toolCalls {
                        print("Agentsphere: tool \(call.name) \(call.arguments)")
                        let chip = ChatMessage(.tool(name: call.name), AgentTool.activity(call.name))
                        insert(chip, before: placeholder.id, of: id)
                        let output = await phoneTools.run(call, allowed: allowed, timeout: 25)
                        let failed = output.hasPrefix("{\"error\"")
                        print("Agentsphere: tool \(call.name) -> \(output.prefix(300))")
                        if failed {
                            updateMessage(chip.id, of: id) { $0.kind = .tool(name: call.name + "!"); $0.text = AgentTool.failure(call.name) }
                            haptics.failure()
                        }
                        toolNotes[chip.id] = "\(call.name) \(call.arguments) → \(output.prefix(240))"
                        history.append(["role": "tool", "tool_call_id": call.id, "content": output])
                    }
                }
                awaitingTools = false
                // Never leave you hanging in silence.
                if full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let sorry = "Sorry, I couldn't finish that. Could you ask me again?"
                    full = sorry
                    DispatchQueue.main.async { MainActor.assumeIsolated { reply.add(sorry) } }
                }
                // Queued after every piece, so it runs once they've all been handled.
                DispatchQueue.main.async { MainActor.assumeIsolated { reply.finish(empty: full.isEmpty) } }
            } catch {
                self.awaitingTools = false
                self.replyArriving = false
                print("Agentsphere: reply failed: \(error.localizedDescription)")
                self.updateMessage(placeholder.id, of: id) { $0.kind = .error; $0.text = error.localizedDescription }
                self.failing.insert(id)
                self.haptics.failure()
                self.phase = .speaking
                self.audio.speak("Sorry, I couldn't answer that.", from: id, prelude: .error)
            }
        }
    }

    // MARK: - Payments

    /// Shop agents your agents can buy from show a badge when their owner is a verified human.
    func isVerified(_ a: Agent) -> Bool {
        a.verified == true || (a.isPublic && worldIdentity != nil && myAgents.contains { $0.id == a.id })
    }

    func refreshIdentity() async {
        guard Config.isConfigured, !offline else { return }
        if let identity = try? await backend.worldIdentity() { worldIdentity = identity }
    }

    /// A World ID result that came back as a link (via Safari) instead of in the sign-in sheet.
    func openURL(_ url: URL) { worldAuth.handle(url) }

    /// Verify you're a human with World ID (for running a shop). Updates badges when it works.
    func verifyWithWorld() async -> WorldAuth.Outcome {
        let outcome = await worldAuth.run(purpose: "verify_shop")
        print("Agentsphere: World ID verify: \(outcome)")
        if case .failed = outcome { haptics.failure() }
        if outcome == .denied { haptics.failure() }
        if outcome == .ok {
            await refreshIdentity()
            haptics.success()
            Task { await refreshNearby(force: true) }
        }
        return outcome
    }

    /// Fetches a shop's menu (fresh on every arrival, so price changes show up).
    func loadMenu(_ id: UUID) async {
        guard Config.isConfigured, !offline else { return }
        if let items = try? await backend.catalog(agentId: id) { menus[id] = items }
    }

    /// Turns one of your public agents into a shop with this menu.
    func openShop(_ a: Agent, items: [CatalogItem]) async throws {
        _ = try await backend.saveCatalog(agentId: a.id, items: items)
        for i in myAgents.indices where myAgents[i].id == a.id { myAgents[i].pricing = "paid" }
        for i in nearby.indices where nearby[i].id == a.id { nearby[i].pricing = "paid"; nearby[i].verified = worldIdentity != nil }
    }

    /// An order update from a shop agent's reply: a card in the conversation, then the outcome spoken.
    private func orderUpdate(_ u: OrderUpdate, agentId: UUID) {
        print("Agentsphere: order \(u.status) \(u.error ?? "")")
        if let mid = liveOrder[agentId], orders[mid] != nil, u.status != "paying" {
            orders[mid]?.apply(u)
        } else if u.status == "paying" || liveOrder[agentId] == nil {
            let m = ChatMessage(.order, u.itemName ?? "Order")
            orders[m.id] = OrderCard(u)
            haptics.light()
            post(m, to: agentId)
            liveOrder[agentId] = m.id
        }
        guard u.status != "paying", let mid = liveOrder.removeValue(forKey: agentId), let card = orders[mid] else { return }
        announce(card, agentId: agentId)
    }

    /// Approve a large purchase: a fresh World ID check, then the wallet pays.
    func approveOrder(messageId: UUID, agentId: UUID) {
        guard var card = orders[messageId], card.status == .needsApproval,
              let approval = card.approvalId, let itemId = card.itemId else { return }
        if phase == .listening { _ = speech.finish(); phase = .idle }
        haptics.light()
        card.status = .approving
        orders[messageId] = card
        Task { @MainActor in
            let outcome = await worldAuth.run(purpose: "checkpoint", approvalId: approval)
            print("Agentsphere: World ID checkpoint: \(outcome)")
            switch outcome {
            case .ok:
                orders[messageId]?.status = .paying
                do {
                    let update = try await backend.pay(agentId: agentId, itemId: itemId, qty: card.qty, approvalId: approval)
                    orders[messageId]?.apply(update)
                } catch {
                    orders[messageId]?.status = .failed
                    orders[messageId]?.detail = error.localizedDescription
                }
            case .cancelled:
                orders[messageId]?.status = .cancelled
                orders[messageId]?.detail = "You closed World ID before approving."
            case .denied:
                orders[messageId]?.status = .denied
                orders[messageId]?.detail = "World ID didn't approve it."
            case .failed(let why):
                orders[messageId]?.status = .failed
                orders[messageId]?.detail = why
            }
            if let done = orders[messageId] { announce(done, agentId: agentId) }
        }
    }

    /// Says how an order went, in the shop agent's voice.
    private func announce(_ card: OrderCard, agentId: UUID) {
        let line: String
        switch card.status {
        case .paid:
            haptics.success()
            line = "Paid. \(card.title), \(Money.usd(card.amount))."
        case .needsApproval:
            // Your approval is needed: make sure you feel it, phone in hand or pocket.
            haptics.attention()
            line = "That's \(Money.usd(card.amount)), more than your wallet pays on its own. Approve it with World ID on your phone."
        case .denied, .cancelled:
            haptics.ended()
            line = "No problem, nothing was paid."
        case .failed:
            haptics.failure()
            line = "The payment didn't go through, so nothing was paid."
        case .paying, .approving:
            return
        }
        guard activeId == agentId else { return }
        if phase != .speaking { phase = .speaking }
        audio.speak(line, from: agentId, prelude: nil)
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
        print("Agentsphere: reply done (\(messages(for: agentId).last?.text.count ?? 0) chars)")
        if empty { updateMessage(messageId, of: agentId) { $0.text = "…" } }
        replyArriving = false
        // Your turn once the last sentence has played (or now, if it already has).
        if activeId == agentId, !audio.isSpeaking { startListening() }
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

    /// Each AirPods reading. A quick turn left or right, from wherever you're facing, picks
    /// that side's agent.
    private func headMoved(yaw: Double) {
        yawFixed = yaw
        lastHeadAt = Date()
        if !hasHeadData {
            hasHeadData = true
            print("Agentsphere: head motion flowing")
        }
        if let side = turns.feed(time: ProcessInfo.processInfo.systemUptime, yaw: yaw) { turned(side) }
        if Date().timeIntervalSince(lastYawLog) > 2 {
            lastYawLog = Date()
            print(String(format: "Agentsphere: head yaw %.0f° pitch %.0f°", yaw, pitchRaw))
        }
        updateScene()
    }

    /// You turned your head toward a side: its agent is picked (bigger on screen, a soft tick
    /// from its side), waiting for a nod or a tap. Not mid-conversation: heads move on their
    /// own while you talk.
    private func turned(_ side: Zone) {
        print("Agentsphere: turned \(side.name)\(activeId == nil ? "" : " (in a conversation: ignored)")")
        lastMove = ("Turned \(side.name.lowercased())", Date())
        guard !training, withMe, lookingEnabled || arranging, activeId == nil, invite == nil else { return }
        let next: Zone? = agent(in: side) == nil ? nil : side   // an empty side picks nobody
        guard next != pickedSide else { return }
        pickedSide = next
        updateFocus()
    }

    private func handleGesture(_ g: HeadGesture) {
        lastGesture = g
        print("Agentsphere: \(g.rawValue) → \(agent(focusedId)?.name ?? "nobody") (picked \(pickedSide?.name ?? "none"), "
              + "talking to \(agent(activeId)?.name ?? "nobody"), screen \(screen)\(arranging ? ", arranging" : ""))")
        lastMove = (g == .nod ? "Yes" : "No", Date())
        guard !training else { return }
        // A question waiting: the gesture answers it.
        if invite != nil {
            inviteAnswer = g
            return
        }
        switch g {
        case .shake:
            // No, any time: while the agent talks, thinks or waits for you. Except while you're
            // mid-sentence, when heads move on their own.
            guard activeId != nil else { return }
            let midSentence = phase == .listening && !transcript.isEmpty && Date().timeIntervalSince(lastHeardAt) < 1.2
            guard !midSentence else {
                print("Agentsphere: shake ignored (you're mid-sentence)")
                return
            }
            endConversation()
        case .nod:
            // Yes: the agent you picked by turning. Otherwise, inside a place's radius, that
            // place (asking which one if you're in more than one).
            guard !arranging, activeId == nil || focusedId != activeId else { return }
            if let target = focusedId, target != activeId, let a = agent(target) {
                wake(a)
            } else if activeId == nil, !zonesHere.isEmpty {
                let here = zonesHere
                if here.count == 1 { wake(here[0]) } else { startInvite(here.map(\.id), choosing: true) }
            }
        }
    }

    // MARK: - Places around you

    /// Asks once you're inside new places' radius, when nothing else is going on.
    private func inviteTick() {
        guard inviteNeeded, invite == nil, activeId == nil, !training, !arranging, !audio.isSpeaking else { return }
        guard announce == .voice, headphonesIn else { inviteNeeded = false; return }
        inviteNeeded = false
        let ids = zonesHere.map(\.id).filter { !declinedZones.contains($0) }
        guard !ids.isEmpty else { return }
        startInvite(zonesHere.map(\.id))
    }

    private func startInvite(_ ids: [UUID], choosing: Bool = false) {
        inviteTask?.cancel()
        let token = UUID()
        invite = Invite(token: token, ids: ids, step: choosing ? .choosing : .asking)
        inviteAnswer = nil
        print("Agentsphere: invite \(ids.compactMap { agent($0)?.name }) (\(choosing ? "which one" : "asking"))")
        inviteTask = Task { @MainActor [weak self] in await self?.runInvite(token, choosing: choosing) }
    }

    /// Closes the question. `declined`: you said no, so these places don't ask again until
    /// you leave and come back.
    func endInvite(declined: Bool, keepMic: Bool = false) {
        guard let inv = invite else { return }
        print("Agentsphere: invite closed (\(declined ? "no" : "done"))")
        if declined { declinedZones.formUnion(inv.ids) }
        invite = nil
        inviteTask?.cancel()
        inviteTask = nil
        if choosingListen {
            choosingListen = false
            _ = speech.finish()
        }
        speech.hints = []
        if !keepMic, !speech.keepsInputOpen { speech.shutdown() }
    }

    /// From the banner: talk to this one.
    func acceptInvite(_ id: UUID) {
        guard let a = agent(id) else { return }
        wake(a)
    }

    private func runInvite(_ token: UUID, choosing: Bool) async {
        func live() -> Bool { invite?.token == token && !Task.isCancelled }
        var agents: [Agent] { (invite?.ids ?? []).compactMap(agent) }
        guard !agents.isEmpty else { return endInvite(declined: false) }

        if !choosing {
            let line = agents.count == 1
                ? "You're at \(agents[0].name). Want to talk?"
                : "\(Words.count(agents.count).capitalized) places around you: \(Self.spokenList(agents.map(\.name))). Want to talk to one?"
            await narrate(line)
            // Yes or no, for up to 15 seconds.
            let deadline = Date().addingTimeInterval(15)
            while live(), inviteAnswer == nil, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            guard live() else { return }
            switch inviteAnswer {
            case .shake?:
                endInvite(declined: true)
                await narrate("Okay.")
                return
            case .nod?:
                break
            case nil:
                return endInvite(declined: false)
            }
            if agents.count == 1 { return wake(agents[0]) }
            invite?.step = .choosing
        }

        // Which one: keeps asking until a name matches, or you say no.
        var misses = 0, silences = 0
        while live() {
            let names = Self.spokenList(agents.map(\.name), or: true)
            await narrate(misses > 0 ? "Sorry, which one? \(names)?" : silences > 0 ? "Which one would you like? \(names)?" : "Which one? \(names)?")
            guard live() else { return }
            inviteAnswer = nil
            switch await listenForChoice(agents, token: token) {
            case .picked(let a):
                print("Agentsphere: picked \(a.name)")
                return wake(a)
            case .missed:
                misses += 1
            case .silence:
                silences += 1
                if silences >= 3 { return endInvite(declined: false) }
            case .no:
                endInvite(declined: true)
                await narrate("Okay.")
                return
            case .gone:
                return
            }
        }
    }

    private enum Choice { case picked(Agent), missed, silence, no, gone }

    /// One answer: matched as you speak (no waiting for the pause), or judged after it.
    private func listenForChoice(_ agents: [Agent], token: UUID) async -> Choice {
        speech.recordsAudio = false
        speech.hints = agents.map(\.name)
        choiceHeard = ""
        choiceHeardAt = Date()
        let error: String? = await withCheckedContinuation { c in speech.begin { c.resume(returning: $0) } }
        if let error {
            print("Agentsphere: which-one listening failed: \(error)")
            try? await Task.sleep(for: .seconds(1))
            return .silence
        }
        choosingListen = true
        audio.cue(.listening, from: narratorId)
        let started = Date()
        defer {
            if choosingListen {
                choosingListen = false
                _ = speech.finish()
            }
        }
        while true {
            try? await Task.sleep(for: .milliseconds(100))
            guard invite?.token == token, !Task.isCancelled else { return .gone }
            if inviteAnswer == .shake { return .no }
            let text = choiceHeard
            if text.isEmpty {
                if Date().timeIntervalSince(started) > 8 { return .silence }
                continue
            }
            if Self.isGoodbye(text, instant: true) || Self.isRefusal(text) { return .no }
            if let a = Self.match(text, among: agents) { return .picked(a) }
            if Date().timeIntervalSince(choiceHeardAt) > 1.4 {
                print("Agentsphere: which one? heard \"\(text)\": no match")
                return .missed
            }
        }
    }

    /// Says a line in the app's own voice and waits for it to finish.
    private func narrate(_ line: String) async {
        print("Agentsphere: narrator: \(line)")
        audio.speak(line, from: narratorId, prelude: nil)
        let deadline = Date().addingTimeInterval(20)
        try? await Task.sleep(for: .milliseconds(150))
        while audio.isSpeaking, Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// "A and B", "A, B and C" (or "A, or B").
    static func spokenList(_ names: [String], or: Bool = false) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + (or ? ", or " : " and ") + names.last!
    }

    static func isRefusal(_ text: String) -> Bool {
        let t = normalized(text)
        return ["no", "nope", "none", "neither", "no thanks", "no thank you", "not now", "nothing", "cancel"].contains(t)
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    /// Rough sound-alike spelling, so "Geo Cafe" finds "Jio Café".
    private static func soundKey(_ w: String) -> String {
        var k = w.replacingOccurrences(of: "ph", with: "f")
        for (a, b) in [("j", "g"), ("c", "k"), ("q", "k"), ("y", "i"), ("z", "s"), ("ee", "i"), ("ea", "i"), ("oo", "u"), ("e", "i")] {
            k = k.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        for ch in k where out.last != ch { out.append(ch) }
        return out
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var prev = row[0]
            row[0] = i
            for j in 1...y.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return 1 - Double(row[y.count]) / Double(max(x.count, y.count))
    }

    /// Which agent a spoken answer names: by name (sound-alikes forgiven) or by order
    /// ("the first one", "second"). Nil when it's unclear.
    static func match(_ text: String, among agents: [Agent]) -> Agent? {
        let t = normalized(text)
        let words = t.split(separator: " ").map(String.init)
        // Pairs too, so "eth global" can match "ETHGlobal".
        let spoken = words + zip(words, words.dropFirst()).map { $0 + $1 }
        let stop: Set<String> = ["the", "a", "an", "of", "and", "at", "to", "my", "for", "in", "on"]
        var scores: [(Agent, Double)] = agents.map { a in
            let name = normalized(a.name)
            if t.replacingOccurrences(of: " ", with: "").contains(name.replacingOccurrences(of: " ", with: "")) { return (a, 1) }
            let tokens = name.split(separator: " ").map(String.init).filter { !stop.contains($0) && $0.count >= 2 }
            let best = tokens.map { tok in
                spoken.map { w in max(similarity(tok, w), similarity(soundKey(tok), soundKey(w))) }.max() ?? 0
            }.max() ?? 0
            return (a, best)
        }
        scores.sort { $0.1 > $1.1 }
        if let top = scores.first, top.1 >= 0.75, scores.count < 2 || top.1 - scores[1].1 >= 0.15 { return top.0 }
        // By order: "first", "the second one", "last"; a bare number only when nothing else says.
        if words.contains("last"), let a = agents.last { return a }
        for (i, w) in ["first", "second", "third"].enumerated() where i < agents.count && words.contains(w) { return agents[i] }
        for (i, w) in [["one", "1"], ["two", "2"], ["three", "3"]].enumerated() where i < agents.count && words.count <= 3 && w.contains(where: words.contains) {
            return agents[i]
        }
        return nil
    }

    // MARK: - Misc

    /// Short name of where sound is going ("AirPods Pro"). Cached: asking the audio session
    /// is too slow to do on every redraw.
    private(set) var routeName = "Headphones"

    /// Back to talking (the mic button in a conversation).
    func resumeListening() {
        typingMode = false
        guard activeId != nil, phase == .idle else { return }
        startListening()
    }

    /// Stop listening and type instead: the mic closes, and stays closed after replies.
    func stopListening() {
        typingMode = true
        guard phase == .listening else { return }
        _ = speech.finish()
        speech.shutdown()
        transcript = ""
        phase = .idle
        print("Agentsphere: typing; mic off")
    }

    func refreshRoute() {
        route = AudioSession.routeDescription
        highQualityMic = AudioSession.highQualityMic
        let name = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "Headphones"
        if name != routeName { print("Agentsphere: audio out → \(name)") }
        routeName = name
        headphonesIn = AudioSession.headphonesConnected
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

#if DEBUG
// MARK: - Sample world (debug builds only)

/// Launch with `-sample YES` to fill the app with the design's example agents, offline,
/// for checking screens in the simulator. `-scene find|arrived|talk|focus` sets a moment.
extension MobileState {
    func loadSampleWorld(scene: String?) {
        offline = true
        conversations = [:]
        orders = [:]
        let here = CLLocationCoordinate2D(latitude: 19.0760, longitude: 72.8777)
        func agent(_ name: String, _ color: BotColor, _ shape: BotShape, greeting: String = "",
                   metres: Double? = nil, bearing: Double = 0, pricing: String = "free", mine: Bool = false,
                   isPublic: Bool = true) -> Agent {
            let spot = metres.map { GeoMath.offset(here, metres: $0, bearing: bearing) }
            return Agent(id: UUID(), name: name, emoji: nil, color: color.hex, shape: shape.rawValue, voiceId: nil,
                         greeting: greeting, context: nil, kind: isPublic ? .public : .personal,
                         anchor: metres == nil ? .body : .geo, visibility: isPublic ? .public : .private,
                         lat: spot?.latitude, lng: spot?.longitude, radiusM: 20, pricing: pricing,
                         priceUsd: nil, walletAddress: nil, isMine: mine, distanceM: metres)
        }
        let helpDesk = agent("Hack Help Desk", .cyan, .circle,
                             greeting: "Hey, I'm the help desk for the hackathon. Ask me about Wi-Fi, mentors, food or the schedule.",
                             metres: 8, bearing: 20)
        nearby = [
            helpDesk,
            agent("Museum Guide · Hall B", .violet, .squircle, metres: 62, bearing: 45),
            agent("Where I parked", .orange, .hexagon, metres: 200, bearing: 300, mine: true, isPublic: false),
            agent("Sponsor Booth 4", .pink, .drop, metres: 280, bearing: 120),
            agent("Corner Café Barista", .green, .capsule, metres: 16, bearing: 250, pricing: "paid", mine: true),
        ]
        myAgents = [
            agent("Daily Planner", .blue, .hexagon, greeting: "Morning. Want the plan for today?"),
            agent("Notes", .yellow, .squircle, greeting: "What should I jot down?"),
            agent("Pitch Coach", .green, .drop, greeting: "Run me through your demo."),
        ]
        myAgents += nearby.filter { $0.isMine == true }
        for shop in nearby where shop.pricing == "paid" {
            menus[shop.id] = [
                CatalogItem(id: UUID(), name: "Cappuccino", priceUsdc: 2),
                CatalogItem(id: UUID(), name: "Masala chai", priceUsdc: 1.5),
                CatalogItem(id: UUID(), name: "Croissant", priceUsdc: 3),
                CatalogItem(id: UUID(), name: "Big breakfast", priceUsdc: 8),
                CatalogItem(id: UUID(), name: "Cold brew", priceUsdc: 3.5),
            ]
        }
        location.simulated = here
        syncPlacement()
        updateArrivals()
        switch UserDefaults.standard.string(forKey: "tab") {
        case "with": screen = .withMe
        case "agents": screen = .agents
        case "create": screen = .agents; creating = true
        case "settings": screen = .settings
        default: break
        }

        switch scene {
        case "focus":
            hasHeadData = true
            focusedId = myAgents[0].id
        case "talk":
            activeId = helpDesk.id
            phase = .listening
            conversations[helpDesk.id] = [
                ChatMessage(.agent, helpDesk.greeting),
                ChatMessage(.user, "Where do I find a mentor for the AI track?"),
                ChatMessage(.agent, "Table 6, beside the stage. Office hours run until 4 pm."),
                ChatMessage(.user, "And the Wi-Fi password?"),
                ChatMessage(.agent, "Network is HackHall. The password is on the back of your badge."),
            ]
            transcript = "what time does judging…"
            lastHeardAt = .distantFuture   // keep it on screen rather than sending
        default:
            break
        }
    }

    /// The sample agent a `-scene` should open in Find.
    var sampleFindTarget: UUID? { nearby.first { $0.name.hasPrefix(sampleScene == "arrived" ? "Hack" : "Museum") }?.id }
    var sampleScene: String? { UserDefaults.standard.string(forKey: "scene") }
}
#endif
