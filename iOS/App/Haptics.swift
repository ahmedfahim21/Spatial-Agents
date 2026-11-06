import CoreHaptics
import Foundation

/// The phone's feel, so you know what happened with it in your pocket:
/// - `attention`: something needs you (approve a payment). Hard to miss.
/// - `success` / `arrived`: it worked, you're here.
/// - `failure`: it didn't. Low and soft, never alarming.
/// - `light`: small acknowledgements (listening, sent, a page lit).
/// - Find-mode pulses: faster and stronger as you get closer.
@MainActor
final class Haptics {
    private var engine: CHHapticEngine?
    private var timer: Timer?
    private var nextPulse = Date.distantPast
    /// Metres beyond arrival; nil stops the pulses.
    var distance: Double? { didSet { if distance == nil { stop() } else { startTimer() } } }

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
        engine?.stoppedHandler = { _ in }
        try? engine?.start()
    }

    func tap(intensity: Float = 1, sharpness: Float = 0.6) {
        play(intensity: intensity, sharpness: sharpness)
    }

    /// Something needs you: two firm knocks and a short buzz.
    func attention() {
        pattern([
            transient(at: 0, intensity: 1, sharpness: 0.8),
            transient(at: 0.14, intensity: 1, sharpness: 0.8),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ], relativeTime: 0.32, duration: 0.35),
        ])
    }

    /// It worked.
    func success() { arrived() }

    /// It didn't: two low, soft taps.
    func failure() {
        pattern([
            transient(at: 0, intensity: 0.7, sharpness: 0.1),
            transient(at: 0.18, intensity: 0.5, sharpness: 0.1),
        ])
    }

    /// A small acknowledgement.
    func light() { play(intensity: 0.45, sharpness: 0.5) }

    /// A conversation ended: one soft fall.
    func ended() {
        pattern([
            transient(at: 0, intensity: 0.6, sharpness: 0.5),
            transient(at: 0.1, intensity: 0.35, sharpness: 0.2),
        ])
    }

    private func transient(at t: Double, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: t)
    }

    private func pattern(_ events: [CHHapticEvent]) {
        guard let engine else { return }
        try? engine.start()
        if let p = try? CHHapticPattern(events: events, parameters: []) {
            try? engine.makePlayer(with: p).start(atTime: 0)
        }
    }

    /// A short "you've arrived" flourish.
    func arrived() {
        guard let engine else { return }
        let events = (0..<3).map { i in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4 + Float(i) * 0.2),
            ], relativeTime: Double(i) * 0.12)
        }
        if let pattern = try? CHHapticPattern(events: events, parameters: []) {
            try? engine.makePlayer(with: pattern).start(atTime: 0)
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let d = distance, Date() >= nextPulse else { return }
        let p = GeoMath.hapticPulse(distance: d)
        play(intensity: Float(p.intensity), sharpness: Float(p.sharpness))
        nextPulse = Date().addingTimeInterval(p.interval)
    }

    private func play(intensity: Float, sharpness: Float) {
        guard let engine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: 0)
        if let pattern = try? CHHapticPattern(events: [event], parameters: []) {
            try? engine.makePlayer(with: pattern).start(atTime: 0)
        }
    }
}
