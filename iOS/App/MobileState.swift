import AVFoundation
import CoreLocation
import Observation
import SwiftUI

enum ConversationPhase: Equatable {
    case idle, greeting, listening, thinking, speaking
}

/// The phone app's brain. Two kinds of agents share one spatial scene:
/// - body-anchored agents sit in a ring around you and travel with you (BodyFollower frame);
/// - geo-anchored agents sit where they are in the world (compass frame), once you've arrived.
/// Look at one and it lights up; nod and it wakes; then you talk hands-free. Shake to end.
@Observable @MainActor
final class MobileState {
    let voices = VoiceRouter()
    let audio: SpatialAudio
    let speech = SpeechInput()
    let location = LocationService()
    let haptics = Haptics()
    private let tracker = HeadTracker()
    private let backend = Backend.shared

    // MARK: State the UI reads

    var myAgents: [Agent] = []
    var nearby: [Agent] = []
    var backendStatus = ""
    var loading = false

    /// Body-anchored agents are around you.
    var withMe = true { didSet { syncPlacement() } }
    var findTargetId: UUID? { didSet { if oldValue != findTargetId { findTargetChanged() } } }
    private(set) var arrived: Set<UUID> = []
    /// Shops' menus, fetched when you arrive at one (shown over it on the map).
    private(set) var menus: [UUID: [CatalogItem]] = [:]

    private(set) var focusedId: UUID?
    /// Head direction: yaw relative to your body (+ = right) and raw pitch, degrees.
    /// Rounded to whole degrees and written only when they change, so screens redraw as fast
    /// as you actually turn rather than at the sensor rate. Audio and focus use the exact values.
    private(set) var headYaw: Double = 0
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
    var conversations: [UUID: [ChatMessage]] = [:]
    /// Orders placed in conversations, by the id of their `.order` message.
    private(set) var orders: [UUID: OrderCard] = [:]
    /// Your World ID verification (a verified human), once you've done it.
    private(set) var worldIdentity: WorldIdentity?
    @ObservationIgnored private let worldAuth = WorldAuth()
    /// The order card of each agent's reply in flight.
    @ObservationIgnored private var liveOrder: [UUID: UUID] = [:]

    /// Where each body-anchored agent sits around you.
    private(set) var zones: [UUID: Zone] = [:]
    /// The user has set their forward direction and arranged their agents.
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

    /// Head yaw relative to your body (body agents).
    @ObservationIgnored private var yawBody: Double = 0
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
        let yaw = yawBody.rounded(), pitch = pitchRaw.rounded(), world = exactWorld?.rounded()
        if yaw != headYaw { headYaw = yaw }
        if pitch != headPitchRaw { headPitchRaw = pitch }
        if world != headWorld { headWorld = world }
    }

    // MARK: Placement

    @ObservationIgnored private var placed: Set<UUID> = []
    /// Body agents' fixed slots around you.
    private var bodySlots: [UUID: Zone] = [:]
    /// Geo agents' bearings, frozen when close or when GPS is poor so they don't jitter.
    private var lockedBearing: [UUID: Double] = [:]
    @ObservationIgnored private var lastFocusAt = Date()
    /// The agent you were looking at just before focus moved, and when it moved. A nod
    /// tips your gaze up and down, which can slide focus for a moment mid-gesture.
    @ObservationIgnored private var previousFocus: (id: UUID, held: TimeInterval, lostAt: Date)?
    @ObservationIgnored private var lookAwaySince: Date?
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

        if let saved = UserDefaults.standard.dictionary(forKey: "zones") as? [String: String] {
            zones = Dictionary(uniqueKeysWithValues: saved.compactMap { k, v in
                guard let id = UUID(uuidString: k), let z = Zone(rawValue: v) else { return nil }
                return (id, z)
            })
        }
        // Once you've set forward, agents stay put: turn right and the one on your right is
        // in front of you. No drift, no re-centering after a long look, no following while
        // walking. Only Recenter (calibrateForward) moves "front".
        tracker.followMe = false
        tracker.onStatus = { [weak self] s in
            print("Agentsphere: tracking status: \(s)")
            self?.trackingStatus = s
        }
        tracker.onYaw = { [weak self] y in
            guard let self else { return }
            self.yawBody = y
            self.lastHeadAt = Date()
            if !self.hasHeadData {
                self.hasHeadData = true
                print("Agentsphere: head motion flowing")
            }
            if Date().timeIntervalSince(self.lastYawLog) > 2 {
                self.lastYawLog = Date()
                print(String(format: "Agentsphere: head yaw %.0f° (fixed %.0f°) pitch %.0f°", y, self.yawFixed, self.pitchRaw))
            }
            self.updateScene()
        }
        tracker.onFixedYaw = { [weak self] y in self?.yawFixed = y }
        tracker.onPitch = { [weak self] p in self?.pitchRaw = p }
        tracker.onGesture = { [weak self] g in self?.handleGesture(g) }
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
        if a.pricing == "paid" { Task { await loadMenu(a.id) } }
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

    /// Keeps each window's agent; a free window (that you didn't empty) takes the next agent
    /// without one, oldest first.
    private func assignZones() {
        let ids = Set(bodyAgents.map(\.id))
        var next = zones.filter { ids.contains($0.key) }
        for a in bodyAgents.reversed() where next[a.id] == nil {
            let used = Set(next.values)
            if let free = Zone.fillOrder.first(where: { !used.contains($0) && !emptiedWindows.contains($0) }) { next[a.id] = free }
        }
        if next != zones { zones = next; saveZones() }
    }

    /// Puts an agent in a window (nil = empty it). Whoever was there leaves; if the agent
    /// was in the other window, the two swap.
    func setWindow(_ zone: Zone, to id: UUID?) {
        var next = zones
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
        zones = next
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
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: zones.map { ($0.key.uuidString, $0.value.rawValue) }), forKey: "zones")
    }

    /// "This is forward": the current head direction becomes the front of your space.
    func calibrateForward() {
        tracker.recenter()
        pitchZero = pitchRaw
        UserDefaults.standard.set(pitchZero, forKey: "pitchZero")
        worldOffset = nil
        calibrateWorld()
        updateScene()
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
    /// For views: the agent's direction from the published (whole-degree) pose.
    func relativeAngle(_ id: UUID) -> Double? { angle(id, yaw: headYaw, world: headWorld) }

    /// For views: the agent's height relative to your gaze (body agents only).
    func relativeElevation(_ id: UUID) -> Double? { elevation(id, pitch: headPitch) }

    /// For audio and focus: the exact pose.
    private func exactAngle(_ id: UUID) -> Double? { angle(id, yaw: yawBody, world: exactWorld) }
    private func exactElevation(_ id: UUID) -> Double? { elevation(id, pitch: pitchRaw - pitchZero) }

    private func angle(_ id: UUID, yaw: Double, world: Double?) -> Double? {
        if let zone = bodySlots[id], withMe { return normalizeAngle(zone.azimuth - yaw) }
        guard let a = agent(id), a.isGeo, let b = bearing(to: a), let world else { return nil }
        return normalizeAngle(b - world)
    }

    private func elevation(_ id: UUID, pitch: Double) -> Double? {
        guard let zone = bodySlots[id], withMe else { return nil }
        return zone.elevation - pitch
    }

    /// Agents you can look at and wake right now.
    var talkable: [Agent] {
        (withMe ? bodyAgents.filter { zones[$0.id] != nil } : []) + nearby.filter { arrived.contains($0.id) }
    }

    private func updateScene() {
        for id in placed {
            guard let rel = exactAngle(id) else { continue }
            audio.setDirection(id: id, azimuth: rel, elevation: exactElevation(id) ?? 0)
        }
        updateFocus()
        publishPose()
    }

    private func updateFocus() {
        // Body agents: how far your gaze is from them, sideways and up/down.
        // Geo agents: sideways only (you're often looking down at the phone while finding).
        // On Create or Settings, your gaze is on the phone: no pings, no waking agents.
        // Body agents need AirPods: without head tracking there's no gaze, and the agent in
        // front would wake on its own.
        let pool = (lookingEnabled ? talkable : talkable.filter { $0.id == activeId })
            .filter { hasHeadData || $0.isGeo }
        let candidates = pool.compactMap { a -> (UUID, Double)? in
            guard let az = exactAngle(a.id) else { return nil }
            guard let el = exactElevation(a.id) else { return (a.id, abs(az)) }
            return (a.id, (az * az + el * el * 1.2).squareRoot())
        }
        var next: UUID?
        if let cur = focusedId, let c = candidates.first(where: { $0.0 == cur }), c.1 < 34 {
            next = cur   // hysteresis: keep focus until clearly looking elsewhere
        } else if let best = candidates.filter({ $0.1 < 24 }).min(by: { $0.1 < $1.1 }) {
            next = best.0
        }
        if next != focusedId {
            print("Agentsphere: focus → \(agent(next)?.name ?? "nobody") (yaw \(Int(yawBody))°, pitch \(Int(pitchRaw - pitchZero))°)")
            if let cur = focusedId {
                previousFocus = (cur, Date().timeIntervalSince(lastFocusAt), Date())
            }
            focusedId = next
            lastFocusAt = Date()
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
        if !hasHeadData { updateScene() }   // phone heading drives focus without AirPods
        beaconTick()

        // Conversation housekeeping.
        guard let active = activeId else { return }
        // A quiet pulse from the agent while it thinks, so the wait never feels dead.
        if phase == .thinking, Date().timeIntervalSince(lastThinkingPulse) > 1.3 {
            lastThinkingPulse = Date()
            audio.cue(.thinking, from: active)
        }
        let looking = exactAngle(active).map { abs($0) < 50 } ?? true
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

    /// Starts talking with an agent (after a nod, or a tap).
    func wake(_ a: Agent) {
        print("Agentsphere: wake \(a.name)")
        if activeId != nil, activeId != a.id { endConversation() }
        activeId = a.id
        lookAwaySince = nil
        asleep.remove(a.id)
        failing.remove(a.id)
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
        if let id = activeId {
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
        print("Agentsphere: listening")
        phase = .listening
        transcript = ""
        lastHeardAt = Date()
        listenStartedAt = Date()
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
        guard phase == .listening else { return }
        transcript = text
        lastHeardAt = Date()
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
        for m in messages(for: id) {
            switch m.kind {
            case .user: turns.append(Backend.Turn(role: "user", content: m.text))
            case .agent: turns.append(Backend.Turn(role: "assistant", content: m.text))
            case .order:
                // So the agent knows what was already bought (and doesn't order it again).
                if let card = orders[m.id], let last = turns.last, last.role == "assistant" {
                    turns[turns.count - 1] = Backend.Turn(role: "assistant", content: last.content + " (Order: \(card.title), \(Money.usd(card.amount)), \(card.outcome).)")
                }
            default: break
            }
        }
        while turns.first?.role == "assistant" { turns.removeFirst() }

        let placeholder = ChatMessage(.agent, "")
        post(placeholder, to: id)
        let reply = ReplySpeaker(state: self, agentId: id, messageId: placeholder.id)
        Task { @MainActor in
            do {
                let full = try await backend.chat(agentId: id, turns: turns, onText: { piece in
                    DispatchQueue.main.async { MainActor.assumeIsolated { reply.add(piece) } }
                }, onOrder: { update in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self.orderUpdate(update, agentId: id) } }
                })
                // Queued after every piece, so it runs once they've all been handled.
                DispatchQueue.main.async { MainActor.assumeIsolated { reply.finish(empty: full.isEmpty) } }
            } catch {
                print("Agentsphere: reply failed: \(error.localizedDescription)")
                self.updateMessage(placeholder.id, of: id) { $0.kind = .error; $0.text = error.localizedDescription }
                self.failing.insert(id)
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

    /// Verify you're a human with World ID (for running a shop). Updates badges when it works.
    func verifyWithWorld() async -> WorldAuth.Outcome {
        let outcome = await worldAuth.run(purpose: "verify_shop")
        print("Agentsphere: World ID verify: \(outcome)")
        if outcome == .ok {
            await refreshIdentity()
            haptics.arrived()
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
            haptics.arrived()
            line = "Paid. \(card.title), \(Money.usd(card.amount))."
        case .needsApproval:
            line = "That's \(Money.usd(card.amount)), more than your wallet pays on its own. Approve it with World ID on your phone."
        case .denied, .cancelled:
            line = "No problem, nothing was paid."
        case .failed:
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
        switch g {
        case .shake:
            // Shake while talking: stop this conversation.
            if activeId != nil { endConversation() }
        case .nod:
            // Nod at the agent you're looking at: wake it.
            guard !arranging, let target = nodTarget, target != activeId, let a = agent(target) else { return }
            wake(a)
        }
    }

    /// Who a nod is meant for: the agent you were settled on as the nod began. If the nod
    /// itself slid focus off it (or onto a neighbour), that one still counts.
    private var nodTarget: UUID? {
        if let p = previousFocus, p.held > 0.4, Date().timeIntervalSince(p.lostAt) < 1.2,
           focusedId == nil || Date().timeIntervalSince(lastFocusAt) < 1.2 {
            return p.id
        }
        return focusedId
    }

    // MARK: - Misc

    func recenter() {
        tracker.recenter()
        worldOffset = nil
        calibrateWorld()
    }

    /// Short name of where sound is going ("AirPods Pro"). Cached: asking the audio session
    /// is too slow to do on every redraw.
    private(set) var routeName = "Headphones"

    /// Back to listening after a pause (the mic button in a conversation).
    func resumeListening() {
        guard activeId != nil, phase == .idle else { return }
        startListening()
    }

    func refreshRoute() {
        route = AudioSession.routeDescription
        highQualityMic = AudioSession.highQualityMic
        routeName = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "Headphones"
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
