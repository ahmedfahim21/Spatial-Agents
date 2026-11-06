import AVFoundation
import Foundation
import PHASE
import simd

/// What the app needs from a spatial audio backend for the agents.
/// Two implementations: `SpatialAudio` (AVAudioEngine) and `PhaseAgentAudio` (PHASE).
protocol AgentAudio: AnyObject {
    var headYaw: Double { get set }
    var voices: VoiceRouter { get }
    func register(id: UUID, azimuth: Double, voiceIndex: Int)
    func remove(id: UUID)
    func setAzimuth(id: UUID, azimuth: Double)
    /// `prelude` plays first on the same agent (e.g. the reply chime), in order with the speech.
    func speak(_ text: String, from id: UUID, prelude: AudioCue?)
    func ping(from id: UUID, high: Bool)
    /// A short sound from the agent's position, played immediately.
    func cue(_ cue: AudioCue, from id: UUID)
    var onSpeakingChanged: ((Bool) -> Void)? { get set }
    /// Called on the main queue before an agent starts a line. Returns true if it just closed
    /// the AirPods mic, so playback waits for them to switch back to stereo.
    var beforeSpeaking: (() -> Bool)? { get set }
}

/// Holds an agent's audio until the output is ready (e.g. AirPods finishing a switch out of
/// headset mode), so nothing is scheduled into a route that's about to be torn down.
/// Synthesis keeps streaming in the meantime, so the wait mostly overlaps TTS latency.
final class PlaybackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var held: [AVAudioPCMBuffer] = []
    private var seconds: Double = 0
    private let play: (AVAudioPCMBuffer) -> Void

    init(open: Bool, play: @escaping (AVAudioPCMBuffer) -> Void) {
        isOpen = open
        self.play = play
    }

    /// Total audio submitted, in seconds.
    var totalSeconds: Double { lock.withLock { seconds } }

    func submit(_ b: AVAudioPCMBuffer) {
        let playNow = lock.withLock { () -> Bool in
            seconds += Double(b.frameLength) / b.format.sampleRate
            if !isOpen { held.append(b) }
            return isOpen
        }
        if playNow { play(b) }
    }

    func open() {
        let flush = lock.withLock { () -> [AVAudioPCMBuffer] in
            isOpen = true
            defer { held = [] }
            return held
        }
        flush.forEach(play)
    }
}

/// Waits for a playback callback, but never longer than `timeout`: if the engine restarts
/// mid-line the callback can be lost, and an agent's speech queue must never hang on it.
func waitForPlayback(timeout: Double, _ schedule: (@escaping @Sendable () -> Void) -> Void) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        let once = OnceFlag()
        let finish: @Sendable () -> Void = { if once.claim() { c.resume() } }
        schedule(finish)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: finish)
    }
}

final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

extension AgentAudio {
    func speak(_ text: String, from id: UUID) { speak(text, from: id, prelude: nil) }
}

/// Earcons, each distinct so you know what happened without looking.
enum AudioCue {
    /// Rising two-note beep: the mic is open, go ahead and talk.
    case listening
    /// Bell: a reply has arrived (plays before the spoken reply).
    case chime
    /// Falling two-note tone: something went wrong.
    case error
}

enum AudioBackendKind: String, CaseIterable, Identifiable {
    case avAudioEngine = "AVAudioEngine"
    case phase = "PHASE"
    var id: String { rawValue }
}

// MARK: - Shared PHASE scene

/// One PHASE engine with a listener and a spatial mixer whose direct path, early reflections
/// and late reverb sends can be changed live through meta parameters.
final class PhaseScene {
    let engine = PHASEEngine(updateMode: .automatic)
    let listener: PHASEListener
    let mixer: PHASESpatialMixerDefinition
    let directSend = PHASENumberMetaParameterDefinition(value: 1, minimum: 0, maximum: 1)
    let earlySend = PHASENumberMetaParameterDefinition(value: 0.5, minimum: 0, maximum: 1)
    let lateSend = PHASENumberMetaParameterDefinition(value: 0.2, minimum: 0, maximum: 1)
    private(set) var startError: String?

    init(reverb: PHASEReverbPreset = .mediumRoom) {
        engine.outputSpatializationMode = .alwaysUseBinaural
        engine.defaultReverbPreset = reverb
        engine.unitsPerMeter = 1

        listener = PHASEListener(engine: engine)
        listener.transform = matrix_identity_float4x4
        try? engine.rootObject.addChild(listener)

        let pipeline = PHASESpatialPipeline(flags: [.directPathTransmission, .earlyReflections, .lateReverb])!
        pipeline.entries[.directPathTransmission]?.sendLevelMetaParameterDefinition = directSend
        pipeline.entries[.earlyReflections]?.sendLevelMetaParameterDefinition = earlySend
        pipeline.entries[.lateReverb]?.sendLevelMetaParameterDefinition = lateSend
        mixer = PHASESpatialMixerDefinition(spatialPipeline: pipeline)
        let distance = PHASEGeometricSpreadingDistanceModelParameters()
        distance.rolloffFactor = 1
        distance.fadeOutParameters = PHASEDistanceModelFadeOutParameters(cullDistance: 2000)
        mixer.distanceModelParameters = distance

        do { try engine.start() } catch {
            startError = error.localizedDescription
            print("PHASE engine error: \(error)")
        }
    }

    deinit { engine.stop() }

    /// macOS 15+: let the system rotate the listener with the AirPods.
    func setSystemHeadTracking(_ on: Bool) {
        if #available(macOS 15.0, *) { listener.automaticHeadTrackingFlags = on ? [.orientation] : [] }
    }

    func makeSource() -> PHASESource {
        let s = PHASESource(engine: engine)
        try? engine.rootObject.addChild(s)
        return s
    }

    func mixerParameters(for source: PHASESource) -> PHASEMixerParameters {
        let p = PHASEMixerParameters()
        p.addSpatialMixerParameters(identifier: mixer.identifier, source: source, listener: listener)
        return p
    }

    /// Metres: right (+ = right), forward (+ = in front), up (+ = up).
    func place(_ obj: PHASEObject, right: Double, forward: Double, up: Double) {
        let p = PHASEObject.right * Float(right) + PHASEObject.forward * Float(forward) + PHASEObject.up * Float(up)
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        obj.transform = m
    }

    func applySends(to event: PHASESoundEvent, direct: Double, early: Double, late: Double) {
        event.metaParameters[directSend.identifier]?.value = NSNumber(value: direct)
        event.metaParameters[earlySend.identifier]?.value = NSNumber(value: early)
        event.metaParameters[lateSend.identifier]?.value = NSNumber(value: late)
    }
}

// MARK: - Agents on PHASE

/// Agents' voices through PHASE: each agent is a point source fed by a push stream,
/// with PHASE's early reflections and room reverb for a sense of space.
final class PhaseAgentAudio: AgentAudio {
    let voices: VoiceRouter
    private let scene = PhaseScene(reverb: .mediumRoom)
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private let radius = 1.5

    private struct Agent {
        let source: PHASESource
        let event: PHASESoundEvent
        let stream: PHASEPushStreamNode
        let assetId: String
        var azimuth: Double
        let voiceIndex: Int
    }
    private var agents: [UUID: Agent] = [:]
    private var speechTail: [UUID: Task<Void, Never>] = [:]

    var headYaw: Double = 0 { didSet { updatePositions() } }

    init(voices: VoiceRouter) {
        self.voices = voices
    }

    /// Called on the main queue when agents start or stop talking (any agent).
    var onSpeakingChanged: ((Bool) -> Void)?
    var beforeSpeaking: (() -> Bool)?
    private var speakingCount = 0
    private func speakingDelta(_ d: Int) {
        DispatchQueue.main.async {
            let was = self.speakingCount > 0
            self.speakingCount = max(0, self.speakingCount + d)
            if was != (self.speakingCount > 0) { self.onSpeakingChanged?(self.speakingCount > 0) }
        }
    }


    func register(id: UUID, azimuth: Double, voiceIndex: Int) {
        guard agents[id] == nil else { return }
        let source = scene.makeSource()
        let streamDef = PHASEPushStreamNodeDefinition(mixerDefinition: scene.mixer, format: format)
        streamDef.normalize = true
        let assetId = "agent-\(id.uuidString)"
        do {
            _ = try scene.engine.assetRegistry.registerSoundEventAsset(rootNode: streamDef, identifier: assetId)
            let event = try PHASESoundEvent(engine: scene.engine, assetIdentifier: assetId,
                                            mixerParameters: scene.mixerParameters(for: source))
            guard let stream = event.pushStreamNodes[streamDef.identifier] else {
                throw VoiceError(message: "PHASE push stream missing")
            }
            scene.applySends(to: event, direct: 1, early: 0.5, late: 0.2)
            event.start(completion: nil)
            agents[id] = Agent(source: source, event: event, stream: stream, assetId: assetId, azimuth: azimuth, voiceIndex: voiceIndex)
        } catch {
            print("PHASE register failed: \(error)")
            scene.engine.rootObject.removeChild(source)
        }
        updatePositions()
    }

    func remove(id: UUID) {
        guard let a = agents.removeValue(forKey: id) else { return }
        speechTail[id]?.cancel()
        speechTail[id] = nil
        a.event.stopAndInvalidate()
        scene.engine.assetRegistry.unregisterAsset(identifier: a.assetId, completion: nil)
        scene.engine.rootObject.removeChild(a.source)
    }

    func setAzimuth(id: UUID, azimuth: Double) {
        agents[id]?.azimuth = azimuth
        updatePositions()
    }

    private func updatePositions() {
        for a in agents.values {
            let rel = (a.azimuth - headYaw) * .pi / 180
            scene.place(a.source, right: sin(rel) * radius, forward: cos(rel) * radius, up: 0)
        }
    }

    func speak(_ text: String, from id: UUID, prelude: AudioCue?) {
        guard let a = agents[id] else { return }
        let previous = speechTail[id]
        let target = format
        let stream = a.stream
        let preludeBuffer = prelude.flatMap { AudioConvert.cue($0, format: target) }
        speechTail[id] = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            self.speakingDelta(1)
            defer { self.speakingDelta(-1) }
            let releasedMic = await MainActor.run { self.beforeSpeaking?() ?? false }
            let gate = PlaybackGate(open: !releasedMic) { stream.scheduleBuffer(buffer: $0) }
            // PHASE follows the device switch itself; just give the AirPods time to settle.
            let settle = Task {
                if releasedMic { try? await Task.sleep(nanoseconds: 900_000_000) }
                gate.open()
            }
            if let preludeBuffer { gate.submit(preludeBuffer) }
            var converter: AVAudioConverter?
            await self.voices.speak(text, voiceIndex: a.voiceIndex) { pcm in
                guard pcm.frameLength > 0 else { return }
                if converter == nil || converter?.inputFormat != pcm.format {
                    converter = AVAudioConverter(from: pcm.format, to: target)
                }
                guard let conv = converter, let out = AudioConvert.convert(pcm, with: conv, to: target) else { return }
                gate.submit(out)
            }
            await settle.value
            // Hold the queue until this line has been rendered (bounded, so it can't hang).
            if gate.totalSeconds > 0, let marker = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1) {
                marker.frameLength = 1
                await waitForPlayback(timeout: gate.totalSeconds + 3) { done in
                    stream.scheduleBuffer(buffer: marker, completionCallbackType: .dataRendered) { _ in done() }
                }
            }
        }
    }

    func ping(from id: UUID, high: Bool) {
        guard let a = agents[id], let tone = AudioConvert.tone(frequency: high ? 990 : 660, format: format) else { return }
        a.stream.scheduleBuffer(buffer: tone)
    }

    func cue(_ cue: AudioCue, from id: UUID) {
        guard let a = agents[id], let buf = AudioConvert.cue(cue, format: format) else { return }
        a.stream.scheduleBuffer(buffer: buf)
    }
}

// MARK: - Shared audio helpers

enum AudioConvert {
    /// Converts one buffer with a long-lived converter (keeps resampler state across chunks).
    static func convert(_ input: AVAudioPCMBuffer, with conv: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
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

    /// Synthesizes an earcon. Notes are (frequency, start, length) with bell-like partials.
    static func cue(_ cue: AudioCue, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        typealias Note = (hz: Double, start: Double, length: Double)
        let notes: [Note]
        let level: Double
        let decay: Double
        switch cue {
        case .listening: notes = [(784, 0, 0.09), (1175, 0.1, 0.16)]; level = 0.22; decay = 9      // G5 → D6
        case .chime:     notes = [(1047, 0, 0.7), (1319, 0.13, 0.8)]; level = 0.2; decay = 4.5     // C6 → E6 bell
        case .error:     notes = [(659, 0, 0.14), (494, 0.15, 0.24)]; level = 0.22; decay = 7      // E5 → B4
        }
        let sr = format.sampleRate
        let total = notes.map { $0.start + $0.length }.max() ?? 0.3
        let frames = AVAudioFrameCount(sr * total)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            var v = 0.0
            for n in notes where t >= n.start && t < n.start + n.length {
                let lt = t - n.start
                let env = min(1, lt / 0.004) * exp(-lt * decay) * min(1, (n.length - lt) / 0.02)
                let w = 2 * Double.pi * n.hz * lt
                v += (sin(w) + 0.35 * sin(2 * w) + 0.12 * sin(3 * w)) * env
            }
            data[i] = Float(v * level)
        }
        return buf
    }

    static func tone(frequency: Double, duration: Double = 0.12, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(sr * duration)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / sr
            let envelope = min(1, t / 0.01) * min(1, (duration - t) / 0.04)
            data[i] = Float(sin(2 * .pi * frequency * t) * 0.25 * max(0, envelope))
        }
        return buf
    }
}
