import AVFoundation
import Foundation

/// What a lab source plays, on loop.
enum LabSound: String, CaseIterable, Identifiable {
    case beep = "Beep"
    case clicks = "Clicks"
    case noise = "Noise"
    case chime = "Chime"
    case voice = "Voice"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .beep: return "dot.radiowaves.left.and.right"
        case .clicks: return "metronome"
        case .noise: return "waveform"
        case .chime: return "bell"
        case .voice: return "person.wave.2"
        }
    }
}

/// A sound placed somewhere in space. Metres: `right` (+ = your right), `forward` (+ = in front), `height` (+ = up).
struct LabSource: Identifiable {
    let id = UUID()
    let slot: Int
    var name: String
    var sound: LabSound
    var right: Double
    var forward: Double
    var height: Double = 0
    var gain: Double = 0.8
    var playing = true
    var reverbBlend: Double = 0.35
    var obstruction: Double = 0
    var occlusion: Double = 0
    /// Degrees per second around you; 0 = stays put.
    var orbitSpeed: Double = 0

    var distance: Double { (right * right + forward * forward + height * height).squareRoot() }
    var groundDistance: Double { (right * right + forward * forward).squareRoot() }
    /// 0 = straight ahead, + = to the right, in the room (not relative to your head).
    var azimuth: Double { atan2(right, forward) * 180 / .pi }
}

enum LabAlgorithm: String, CaseIterable, Identifiable {
    case hrtfHQ = "HRTF HQ"
    case hrtf = "HRTF (lopsided)"
    case sphericalHead = "Spherical head"
    case equalPower = "Equal-power pan"
    case soundField = "Sound field"
    var id: String { rawValue }
    var value: AVAudio3DMixingRenderingAlgorithm {
        switch self {
        case .hrtfHQ: return .HRTFHQ
        case .hrtf: return .HRTF
        case .sphericalHead: return .sphericalHead
        case .equalPower: return .equalPowerPanning
        case .soundField: return .soundField
        }
    }
}

enum LabDistanceModel: String, CaseIterable, Identifiable {
    case inverse = "Inverse"
    case linear = "Linear"
    case exponential = "Exponential"
    var id: String { rawValue }
    var value: AVAudioEnvironmentDistanceAttenuationModel {
        switch self {
        case .inverse: return .inverse
        case .linear: return .linear
        case .exponential: return .exponential
        }
    }
}

enum LabReverb: String, CaseIterable, Identifiable {
    case smallRoom = "Small room"
    case mediumRoom = "Medium room"
    case largeRoom = "Large room"
    case mediumHall = "Medium hall"
    case largeHall = "Large hall"
    case cathedral = "Cathedral"
    case plate = "Plate"
    var id: String { rawValue }
    var value: AVAudioUnitReverbPreset {
        switch self {
        case .smallRoom: return .smallRoom
        case .mediumRoom: return .mediumRoom
        case .largeRoom: return .largeRoom
        case .mediumHall: return .mediumHall
        case .largeHall: return .largeHall
        case .cathedral: return .cathedral
        case .plate: return .plate
        }
    }
}

/// A playground for hearing how placement, distance and room settings change a sound.
/// Runs its own engine so experiments never disturb the agents.
final class SoundLab: ObservableObject {
    static let maxSources = 12

    @Published var sources: [LabSource] = []
    @Published var selectedId: UUID?
    @Published var headYaw: Double = 0

    @Published var followHead = true { didSet { updatePositions() } }
    /// macOS 15+: let the system rotate the listener with the AirPods (lower latency than our own tracking).
    @Published var systemHeadTracking = false { didSet { applyHeadTrackingMode() } }
    /// Extra treble cut (dB) for sounds behind your head. HRTFs alone give only ~5 dB, too subtle for most people.
    @Published var backDarkening: Double = 10 { didSet { updatePositions() } }
    /// The engine sends the same echo level at every distance, so far sources become almost
    /// pure echo and lose their direction. 0 = engine default, 1 = echo falls 10 dB per decade.
    @Published var echoFalloff: Double = 0.7 { didSet { updatePositions() } }
    /// Treble cut (dB) per doubling of distance beyond the reference distance.
    @Published var airAbsorption: Double = 3 { didSet { updatePositions() } }
    @Published var algorithm: LabAlgorithm = .hrtfHQ { didSet { applyPlayerSettings() } }
    @Published var distanceModel: LabDistanceModel = .inverse { didSet { applyEnvironment() } }
    @Published var referenceDistance: Double = 1 { didSet { applyEnvironment() } }
    @Published var maximumDistance: Double = 200 { didSet { applyEnvironment() } }
    @Published var rolloff: Double = 1 { didSet { applyEnvironment() } }
    @Published var reverbOn = true { didSet { applyEnvironment() } }
    @Published var reverb: LabReverb = .mediumRoom { didSet { applyEnvironment() } }
    @Published var reverbLevel: Double = -6 { didSet { applyEnvironment() } }
    @Published var masterVolume: Double = 0.9 { didSet { environment.outputVolume = Float(masterVolume) } }

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var players: [AVAudioPlayerNode] = []
    /// player → eq (back darkening) → spatial mixer → environment. 3D settings live on the mixer.
    private var eqs: [AVAudioUnitEQ] = []
    private var spatials: [AVAudioMixerNode] = []
    private var buffers: [LabSound: AVAudioPCMBuffer] = [:]
    private var orbitTimer: Timer?
    private var lastOrbitTick = Date()
    private var started = false
    private let synth = AVSpeechSynthesizer()

    init() {
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.outputType = .headphones
        // Fixed pool of players, all wired before the engine starts, so adding a
        // source never has to stop the engine.
        for _ in 0..<Self.maxSources {
            let p = AVAudioPlayerNode()
            // Band 0: back darkening. Band 1: air absorption.
            let eq = AVAudioUnitEQ(numberOfBands: 2)
            for (band, hz) in zip(eq.bands, [3000.0, 5000.0]) {
                band.filterType = .highShelf
                band.frequency = Float(hz)
                band.gain = 0
                band.bypass = false
            }
            let m = AVAudioMixerNode()
            engine.attach(p); engine.attach(eq); engine.attach(m)
            engine.connect(p, to: eq, format: format)
            engine.connect(eq, to: m, format: format)
            engine.connect(m, to: environment, format: format)
            m.sourceMode = .spatializeIfMono
            players.append(p); eqs.append(eq); spatials.append(m)
        }
        for s in [LabSound.beep, .clicks, .noise, .chime] { buffers[s] = makeBuffer(s) }
        makeVoiceBuffer()
        applyEnvironment()
        applyPlayerSettings()
        environment.outputVolume = Float(masterVolume)
    }

    /// Starts the engine the first time the lab window opens.
    func activate() {
        guard !started else { return }
        started = true
        engine.prepare()
        do { try engine.start() } catch { print("Sound Lab engine error: \(error)") }
        orbitTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tickOrbits() }
        if sources.isEmpty {
            add(.voice, right: -2, forward: 1)
            add(.beep, right: 6, forward: 6)
            selectedId = sources.first?.id
        }
    }

    /// Silences everything (lab window closed).
    func deactivate() {
        for p in players { p.stop() }
        for i in sources.indices { sources[i].playing = false }
    }

    // MARK: - Sources

    @discardableResult
    func add(_ sound: LabSound, right: Double, forward: Double) -> UUID? {
        let used = Set(sources.map(\.slot))
        guard let slot = (0..<Self.maxSources).first(where: { !used.contains($0) }) else { return nil }
        let n = sources.filter { $0.sound == sound }.count + 1
        let s = LabSource(slot: slot, name: "\(sound.rawValue) \(n)", sound: sound, right: right, forward: forward)
        sources.append(s)
        selectedId = s.id
        applySource(s)
        restart(s)
        return s.id
    }

    func remove(_ id: UUID) {
        guard let s = sources.first(where: { $0.id == id }) else { return }
        players[s.slot].stop()
        sources.removeAll { $0.id == id }
        if selectedId == id { selectedId = sources.first?.id }
    }

    func move(_ id: UUID, right: Double, forward: Double) {
        update(id) { $0.right = right; $0.forward = forward }
    }

    /// Changes a source and pushes the change into the audio graph.
    func update(_ id: UUID, _ change: (inout LabSource) -> Void) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        let before = sources[i]
        change(&sources[i])
        let after = sources[i]
        applySource(after)
        if before.sound != after.sound || before.playing != after.playing { restart(after) }
    }

    func setAll(playing: Bool) {
        for s in sources { update(s.id) { $0.playing = playing } }
    }

    /// Plays the source once from the start, so you can compare positions.
    func retrigger(_ id: UUID) {
        guard let s = sources.first(where: { $0.id == id }) else { return }
        restart(s)
    }

    private func restart(_ s: LabSource) {
        let p = players[s.slot]
        p.stop()
        guard s.playing, started, let buf = buffers[s.sound] else { return }
        p.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
        p.play()
    }

    // MARK: - Positions

    func setHeadYaw(_ yaw: Double) {
        headYaw = yaw
        updatePositions()
    }

    private func updatePositions() {
        for s in sources { applyPosition(s) }
    }

    private func applyPosition(_ s: LabSource) {
        // Rotate the world opposite the head so sources stay fixed in the room.
        // With system head tracking, macOS rotates the listener instead, so we don't.
        let yaw = followHead && !systemHeadTracking ? headYaw : 0
        let rel = (s.azimuth - yaw) * .pi / 180
        let d = s.groundDistance
        // Listener faces -Z; +X is right; +Y is up.
        let m = spatials[s.slot]
        m.position = AVAudio3DPoint(x: Float(sin(rel) * d), y: Float(s.height), z: Float(-cos(rel) * d))

        // Back darkening: 0 at the sides and in front, full directly behind your head.
        let headRel = (s.azimuth - (followHead || systemHeadTracking ? headYaw : 0)) * .pi / 180
        let behind = max(0, -cos(headRel))
        eqs[s.slot].bands[0].gain = Float(-backDarkening * behind)
        m.volume = Float(s.gain * pow(10, -backDarkening * 0.15 * behind / 20))

        // Distance cues the engine doesn't give on its own.
        let far = max(s.distance, referenceDistance) / referenceDistance
        eqs[s.slot].bands[1].gain = Float(max(-30, -airAbsorption * log2(far)))
        m.reverbBlend = Float(effectiveEcho(s))
    }

    /// Echo send after distance falloff. Send power tracks the blend, so blend ∝ d^-falloff
    /// makes the echo drop 10·falloff dB per decade while the direct sound drops 20 dB.
    func effectiveEcho(_ s: LabSource) -> Double {
        let far = max(s.distance, referenceDistance) / referenceDistance
        return min(1, s.reverbBlend * pow(far, -echoFalloff))
    }

    private func applyHeadTrackingMode() {
        if #available(macOS 15.0, *) {
            environment.isListenerHeadTrackingEnabled = systemHeadTracking
        }
        updatePositions()
    }

    var systemHeadTrackingAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    private func applySource(_ s: LabSource) {
        let p = spatials[s.slot]
        p.obstruction = Float(s.obstruction)
        p.occlusion = Float(s.occlusion)
        applyPosition(s)
    }

    private func tickOrbits() {
        let now = Date()
        let dt = now.timeIntervalSince(lastOrbitTick)
        lastOrbitTick = now
        for s in sources where s.orbitSpeed != 0 {
            let a = (s.azimuth + s.orbitSpeed * dt) * .pi / 180
            let d = s.groundDistance
            update(s.id) { $0.right = sin(a) * d; $0.forward = cos(a) * d }
        }
    }

    // MARK: - Room

    private func applyEnvironment() {
        let d = environment.distanceAttenuationParameters
        d.distanceAttenuationModel = distanceModel.value
        d.referenceDistance = Float(referenceDistance)
        d.maximumDistance = Float(max(maximumDistance, referenceDistance + 0.1))
        d.rolloffFactor = Float(rolloff)
        updatePositions()
        let r = environment.reverbParameters
        r.enable = reverbOn
        r.loadFactoryReverbPreset(reverb.value)
        r.level = Float(reverbLevel)
    }

    private func applyPlayerSettings() {
        for m in spatials { m.renderingAlgorithm = algorithm.value }
    }

    /// Loudness the distance model should give at `distance`, in dB (0 = reference loudness).
    func expectedGainDB(at distance: Double) -> Double {
        let ref = referenceDistance, maxD = max(maximumDistance, ref + 0.1)
        let d = min(max(distance, ref), maxD)
        let g: Double
        switch distanceModel {
        case .inverse: g = ref / (ref + rolloff * (d - ref))
        case .linear: g = max(0, 1 - rolloff * (d - ref) / (maxD - ref))
        case .exponential: g = pow(d / ref, -rolloff)
        }
        return g <= 0 ? -120 : 20 * log10(g)
    }

    // MARK: - Sounds

    private func makeBuffer(_ sound: LabSound) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let length: Double = sound == .chime ? 2 : 1
        let frames = AVAudioFrameCount(sr * length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let out = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        var pink = (0.0, 0.0, 0.0)
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            var v = 0.0
            switch sound {
            case .beep:
                if t < 0.15 {
                    let env = min(1, t / 0.005) * min(1, (0.15 - t) / 0.03)
                    v = sin(2 * .pi * 880 * t) * env * 0.5
                }
            case .clicks:
                let phase = t.truncatingRemainder(dividingBy: 0.25)
                if phase < 0.004 { v = Double.random(in: -1...1) * (1 - phase / 0.004) * 0.8 }
            case .noise:
                // Cheap pink-ish noise: broadband, the easiest sound to localise.
                let w = Double.random(in: -1...1)
                pink.0 = 0.997 * pink.0 + 0.029591 * w
                pink.1 = 0.985 * pink.1 + 0.032534 * w
                pink.2 = 0.950 * pink.2 + 0.048056 * w
                v = (pink.0 + pink.1 + pink.2 + w * 0.05) * 2.5
            case .chime:
                let env = min(1, t / 0.003) * exp(-t * 3)
                v = (sin(2 * .pi * 660 * t) + 0.6 * sin(2 * .pi * 990 * t) + 0.3 * sin(2 * .pi * 1320 * t)) * env * 0.3
            case .voice:
                break
            }
            out[i] = Float(v)
        }
        return buf
    }

    /// Renders a short phrase once, then loops it with a pause.
    private func makeVoiceBuffer() {
        let utterance = AVSpeechUtterance(string: "Hello. I'm over here.")
        utterance.voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        var samples: [Float] = []
        var converter: AVAudioConverter?
        let target = format
        synth.write(utterance) { [weak self] buffer in
            guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                // End of speech: add a pause and publish the buffer.
                samples += [Float](repeating: 0, count: Int(target.sampleRate * 1.2))
                guard let buf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(samples.count)),
                      let out = buf.floatChannelData?[0] else { return }
                buf.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: samples.count) }
                DispatchQueue.main.async {
                    self.buffers[.voice] = buf
                    for s in self.sources where s.sound == .voice { self.restart(s) }
                }
                return
            }
            if converter == nil || converter?.inputFormat != pcm.format {
                converter = AVAudioConverter(from: pcm.format, to: target)
            }
            guard let conv = converter, let out = Self.convert(pcm, with: conv, to: target),
                  let data = out.floatChannelData?[0] else { return }
            samples += UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        }
    }

    private static func convert(_ input: AVAudioPCMBuffer, with conv: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }
}
