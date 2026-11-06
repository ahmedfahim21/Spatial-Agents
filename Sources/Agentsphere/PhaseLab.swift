import AVFoundation
import Foundation
import PHASE
import simd

// MARK: - Sound Lab on PHASE

/// Plays Sound Lab sources through PHASE so they can be compared with AVAudioEngine.
/// Pure PHASE: none of the lab's own tricks (back darkening, air absorption, echo falloff).
final class PhaseLabBackend {
    private let scene = PhaseScene(reverb: .mediumRoom)
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var registered: Set<LabSound> = []
    private var sources: [Int: PHASESource] = [:]
    private var events: [Int: PHASESoundEvent] = [:]

    var direct = 1.0, early = 0.5, late = 0.2

    var startError: String? { scene.startError }

    func setReverb(_ preset: PHASEReverbPreset) { scene.engine.defaultReverbPreset = preset }
    func setSystemHeadTracking(_ on: Bool) { scene.setSystemHeadTracking(on) }

    /// Registers a looping event for a lab sound (once per sound type).
    private func ensureAsset(_ sound: LabSound, buffer: AVAudioPCMBuffer) -> Bool {
        if registered.contains(sound) { return true }
        guard let ch = buffer.floatChannelData?[0] else { return false }
        let data = Data(bytes: ch, count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
        let soundId = "lab-sound-\(sound.rawValue)"
        let eventId = "lab-event-\(sound.rawValue)"
        do {
            _ = try scene.engine.assetRegistry.registerSoundAsset(data: data, identifier: soundId, format: format, normalizationMode: .dynamic)
            let sampler = PHASESamplerNodeDefinition(soundAssetIdentifier: soundId, mixerDefinition: scene.mixer)
            sampler.playbackMode = .looping
            sampler.cullOption = .sleepWakeAtRealtimeOffset
            _ = try scene.engine.assetRegistry.registerSoundEventAsset(rootNode: sampler, identifier: eventId)
            registered.insert(sound)
            return true
        } catch {
            print("PHASE lab asset failed: \(error)")
            return false
        }
    }

    func play(slot: Int, sound: LabSound, buffer: AVAudioPCMBuffer) {
        stop(slot: slot)
        guard ensureAsset(sound, buffer: buffer) else { return }
        let source = sources[slot] ?? scene.makeSource()
        sources[slot] = source
        do {
            let event = try PHASESoundEvent(engine: scene.engine, assetIdentifier: "lab-event-\(sound.rawValue)",
                                            mixerParameters: scene.mixerParameters(for: source))
            scene.applySends(to: event, direct: direct, early: early, late: late)
            event.start(completion: nil)
            events[slot] = event
        } catch {
            print("PHASE lab event failed: \(error)")
        }
    }

    func stop(slot: Int) {
        events.removeValue(forKey: slot)?.stopAndInvalidate()
    }

    func stopAll() {
        for slot in Array(events.keys) { stop(slot: slot) }
    }

    func place(slot: Int, right: Double, forward: Double, up: Double, gain: Double) {
        let s = sources[slot] ?? scene.makeSource()
        sources[slot] = s
        s.gain = gain
        scene.place(s, right: right, forward: forward, up: up)
    }

    func applySends() {
        for e in events.values { scene.applySends(to: e, direct: direct, early: early, late: late) }
    }
}
