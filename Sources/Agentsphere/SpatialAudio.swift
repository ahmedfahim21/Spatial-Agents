import AVFoundation
import Foundation

/// Places each agent's voice at a fixed point in the room. Sources are moved
/// opposite to your head, so when you turn toward an agent it ends up in front of you.
final class SpatialAudio {
    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private let radius: Float = 1.5

    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var azimuths: [UUID: Double] = [:]
    private var synths: [UUID: AVSpeechSynthesizer] = [:]
    private var voices: [UUID: AVSpeechSynthesisVoice] = [:]

    var headYaw: Double = 0 { didSet { updatePositions() } }

    init() {
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.outputType = .headphones
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1
        environment.reverbParameters.enable = false
        startEngine()
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        engine.prepare()
        do { try engine.start() } catch { print("Agentsphere audio engine error: \(error)") }
    }

    // MARK: - Sources

    func register(id: UUID, azimuth: Double, voiceIndex: Int) {
        guard players[id] == nil else { return }
        let player = AVAudioPlayerNode()
        engine.stop()
        engine.attach(player)
        engine.connect(player, to: environment, format: format)
        player.renderingAlgorithm = .HRTFHQ
        player.sourceMode = .spatializeIfMono
        players[id] = player
        azimuths[id] = azimuth
        synths[id] = AVSpeechSynthesizer()
        voices[id] = Self.pickVoice(index: voiceIndex)
        startEngine()
        for p in players.values { p.play() }
        updatePositions()
    }

    func remove(id: UUID) {
        guard let player = players[id] else { return }
        player.stop()
        engine.detach(player)
        players[id] = nil
        azimuths[id] = nil
        synths[id] = nil
        voices[id] = nil
    }

    func setAzimuth(id: UUID, azimuth: Double) {
        azimuths[id] = azimuth
        updatePositions()
    }

    private func updatePositions() {
        for (id, az) in azimuths {
            let rel = (az - headYaw) * .pi / 180
            // Listener faces -Z; +X is to the right.
            players[id]?.position = AVAudio3DPoint(
                x: Float(sin(rel)) * radius,
                y: 0,
                z: -Float(cos(rel)) * radius
            )
        }
    }

    // MARK: - Sound

    /// Speaks text from the agent's position in the room.
    func speak(_ text: String, from id: UUID) {
        guard let player = players[id], let synth = synths[id] else { return }
        startEngine()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voices[id]
        let box = ConverterBox()
        let target = format
        synth.write(utterance) { [weak self] buffer in
            guard let self,
                  let pcm = buffer as? AVAudioPCMBuffer,
                  pcm.frameLength > 0 else { return }
            if box.converter == nil || box.converter?.inputFormat != pcm.format {
                box.converter = AVAudioConverter(from: pcm.format, to: target)
            }
            guard let conv = box.converter, let out = self.convert(pcm, with: conv) else { return }
            player.scheduleBuffer(out, completionHandler: nil)
            if !player.isPlaying { player.play() }
        }
    }

    /// A short tone from the agent's position. `high` for "sent", low for "you're facing me".
    func ping(from id: UUID, high: Bool) {
        guard let player = players[id], let tone = makeTone(frequency: high ? 990 : 660) else { return }
        startEngine()
        player.scheduleBuffer(tone, completionHandler: nil)
        if !player.isPlaying { player.play() }
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

    private static func pickVoice(index: Int) -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        guard !english.isEmpty else { return nil }
        return english[index % english.count]
    }
}

private final class ConverterBox { var converter: AVAudioConverter? }
private final class Flag { var value = false }
