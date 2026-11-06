import CoreHaptics
import Foundation

/// Find-mode pulses: faster and stronger as you get closer.
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
