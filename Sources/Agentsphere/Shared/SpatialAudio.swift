import AVFoundation
import Foundation

/// Places each agent's voice at a fixed point in the room. Sources are moved
/// opposite to your head, so when you turn toward an agent it ends up in front of you.
final class SpatialAudio: AgentAudio {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private let radius: Float = 1.5

    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var azimuths: [UUID: Double] = [:]
    private var elevations: [UUID: Double] = [:]
    private var voiceIndex: [UUID: Int] = [:]
    /// Each agent speaks one line at a time; a new line waits for the previous one.
    private var speechTail: [UUID: Task<Void, Never>] = [:]
    let voices: VoiceRouter
    private var restartWork: DispatchWorkItem?
    private var recoverAttempts = 0
    private var lastConfigChange = Date.distantPast
    private var watchdog: Timer?

    /// Called on the main queue when agents start or stop talking (any agent).
    var onSpeakingChanged: ((Bool) -> Void)?
    var beforeSpeaking: (() -> Bool)?
    /// Lines queued or playing. Counted from when a line is queued, not when it starts, so a
    /// reply's sentences don't read as "stopped talking" in the gaps between them.
    private var speakingCount = 0
    var isSpeaking: Bool { speakingCount > 0 }
    private func speakingDelta(_ d: Int) {
        let apply = {
            let was = self.speakingCount > 0
            self.speakingCount = max(0, self.speakingCount + d)
            if was != (self.speakingCount > 0) { self.onSpeakingChanged?(self.speakingCount > 0) }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    var headYaw: Double = 0 { didSet { updatePositions() } }

    init(voices: VoiceRouter) {
        self.voices = voices
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.outputType = .headphones
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.reverbParameters.enable = false
        startEngine()
        // macOS stops the engine when the output changes (AirPods switching in and out of
        // headset mode, 44.1 ↔ 48 kHz). Changes come in bursts: recover once things settle.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lastConfigChange = Date()
            self.recoverAttempts = 0
            self.scheduleRecover(after: 0.4)
        }
        // Belt and braces: if the engine is down and no notification came, bring it back.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, !self.engine.isRunning, self.restartWork == nil, !self.players.isEmpty else { return }
            self.scheduleRecover(after: 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    deinit { watchdog?.invalidate() }

    private func startEngine() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do { try engine.start() } catch { print("Agentsphere audio engine error: \(error)") }
    }

    private func scheduleRecover(after delay: Double) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.restartWork = nil
            self?.recover()
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Restarts the engine against the current output, retrying with backoff until it runs.
    private func recover() {
        if engine.isRunning {
            recoverAttempts = 0
            for p in players.values where !p.isPlaying { p.play() }
            return
        }
        recoverAttempts += 1
        print("Agentsphere: audio output changed; restarting engine (attempt \(recoverAttempts))")
        engine.stop()
        // The hardware sample rate may have changed; reconnect the final stage to match it.
        let hw = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hw.sampleRate > 0 ? hw : nil)
        startEngine()
        if engine.isRunning {
            for p in players.values { p.play() }
            print("Agentsphere: audio engine running (\(Int(hw.sampleRate)) Hz)")
        } else if recoverAttempts < 10 {
            scheduleRecover(after: min(0.4 * Double(recoverAttempts), 3))
        } else {
            print("Agentsphere: audio engine failed to restart; the watchdog will keep trying")
            recoverAttempts = 0
        }
    }

    /// After the AirPods mic closes, wait for them to finish switching back to stereo.
    private func waitForStableOutput() async {
        try? await Task.sleep(nanoseconds: 500_000_000)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let ready = await MainActor.run { self.engine.isRunning && Date().timeIntervalSince(self.lastConfigChange) > 0.6 }
            if ready { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Schedules a buffer, starting the player only when the engine runs
    /// (playing a node on a stopped engine raises an exception).
    private func enqueue(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode) {
        player.scheduleBuffer(buffer, completionHandler: nil)
        if engine.isRunning, !player.isPlaying { player.play() }
    }

    // MARK: - Sources

    func register(id: UUID, azimuth: Double, voiceIndex: Int) {
        guard players[id] == nil else { return }
        let player = AVAudioPlayerNode()
        // Hot-attach: the environment node accepts new inputs while running, so adding an
        // agent doesn't stop the engine (a restart reloads HRTF data and stalls the UI).
        engine.attach(player)
        engine.connect(player, to: environment, format: format)
        player.renderingAlgorithm = .HRTFHQ
        player.sourceMode = .spatializeIfMono
        players[id] = player
        azimuths[id] = azimuth
        self.voiceIndex[id] = voiceIndex
        startEngine()
        if engine.isRunning { player.play() }
        updatePositions()
    }

    func remove(id: UUID) {
        guard let player = players[id] else { return }
        player.stop()
        engine.detach(player)
        players[id] = nil
        azimuths[id] = nil
        elevations[id] = nil
        voiceIndex[id] = nil
        speechTail[id]?.cancel()
        speechTail[id] = nil
    }

    /// Per-agent loudness, 0...1 (e.g. a beacon that grows as you approach).
    func setGain(id: UUID, gain: Double) {
        players[id]?.volume = Float(max(0, min(1, gain)))
    }

    func setAzimuth(id: UUID, azimuth: Double) {
        azimuths[id] = azimuth
        updatePosition(id)
    }

    /// Direction with height: elevation in degrees, + = above ear level.
    func setDirection(id: UUID, azimuth: Double, elevation: Double) {
        azimuths[id] = azimuth
        elevations[id] = elevation
        updatePosition(id)
    }

    private func updatePositions() {
        for id in azimuths.keys { updatePosition(id) }
    }

    /// Moves one agent's source. Called per agent at the head-tracking rate, so it only
    /// touches that agent's node.
    private func updatePosition(_ id: UUID) {
        guard let az = azimuths[id], let player = players[id] else { return }
        let rel = (az - headYaw) * .pi / 180
        let el = (elevations[id] ?? 0) * .pi / 180
        // Listener faces -Z; +X is to the right; +Y is up.
        player.position = AVAudio3DPoint(
            x: Float(sin(rel) * cos(el)) * radius,
            y: Float(sin(el)) * radius,
            z: -Float(cos(rel) * cos(el)) * radius
        )
    }

    // MARK: - Sound

    /// Speaks text from the agent's position in the room.
    /// Speaks text from the agent's position. The voice engine (ElevenLabs, Kokoro or Apple)
    /// streams chunks; each is resampled and scheduled on the agent's spatial player.
    func speak(_ text: String, from id: UUID, prelude: AudioCue?) {
        guard let player = players[id], let index = voiceIndex[id] else { return }
        startEngine()
        let previous = speechTail[id]
        let target = format
        let preludeBuffer = prelude.flatMap { AudioConvert.cue($0, format: target) }
        speakingDelta(1)
        speechTail[id] = Task { [weak self] in
            defer { self?.speakingDelta(-1) }
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            // If this line closed the AirPods mic, hold playback until they're back in stereo.
            let releasedMic = await MainActor.run { self.beforeSpeaking?() ?? false }
            let gate = PlaybackGate(open: !releasedMic) { [weak self] in self?.enqueue($0, on: player) }
            let settle = Task {
                if releasedMic { await self.waitForStableOutput() }
                gate.open()
            }
            // The prelude (e.g. reply chime) plays while the voice is still being synthesized.
            if let preludeBuffer { gate.submit(preludeBuffer) }
            let box = ConverterBox()
            await self.voices.speak(text, voiceIndex: index) { pcm in
                guard pcm.frameLength > 0 else { return }
                if box.converter == nil || box.converter?.inputFormat != pcm.format {
                    box.converter = AVAudioConverter(from: pcm.format, to: target)
                }
                guard let conv = box.converter, let out = self.convert(pcm, with: conv) else { return }
                gate.submit(out)
            }
            await settle.value
            // Hold the queue until this line finishes playing (bounded, so it can't hang).
            if gate.totalSeconds > 0, let marker = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1) {
                marker.frameLength = 1
                await waitForPlayback(timeout: gate.totalSeconds + 3) { done in
                    player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { _ in done() }
                }
            }
        }
    }

    func cue(_ cue: AudioCue, from id: UUID) {
        guard let player = players[id], let buf = AudioConvert.cue(cue, format: format) else { return }
        startEngine()
        enqueue(buf, on: player)
    }

    /// A short tone from the agent's position. `high` for "sent", low for "you're facing me".
    func ping(from id: UUID, high: Bool) {
        guard let player = players[id], let tone = makeTone(frequency: high ? 990 : 660) else { return }
        startEngine()
        enqueue(tone, on: player)
    }

    private func makeTone(frequency: Double, duration: Double = 0.12) -> AVAudioPCMBuffer? {
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

    private func convert(_ input: AVAudioPCMBuffer, with conv: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let fed = Flag()
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, outStatus in
            if fed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed.value = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }

}

private final class ConverterBox { var converter: AVAudioConverter? }
private final class Flag { var value = false }
