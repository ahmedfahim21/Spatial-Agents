import CoreMotion
import Foundation

enum HeadGesture: String {
    case nod = "Nod"
    case shake = "Shake"
}

/// Reads AirPods head orientation (AirPods Pro, Max, 3rd/4th gen; macOS 14+).
final class HeadTracker {
    private let manager = CMHeadphoneMotionManager()
    private var zeroYaw: Double?
    private var lastRawYaw: Double = 0
    private let gestures = GestureDetector()
    private let yawFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.02)
    private let pitchFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.02)
    /// Unwrapped yaw so the filter never sees a jump from +180 to -180.
    private var unwrappedYaw: Double?

    /// Called on the main queue with smoothed yaw in degrees: 0 = calibrated front, positive = turned right.
    var onYaw: ((Double) -> Void)?
    /// Called on the main queue with smoothed pitch in degrees: positive = looking up.
    var onPitch: ((Double) -> Void)?
    var onGesture: ((HeadGesture) -> Void)?
    var onStatus: ((String) -> Void)?
    var invert = false
    /// 0.5 (stiff) ... 2 (twitchy). Scales the speed and size a nod or shake needs.
    var sensitivity: Double {
        get { gestures.sensitivity }
        set { gestures.sensitivity = newValue }
    }
    /// How fast the head is turning right now, degrees per second.
    var yawSpeed: Double { gestures.yawSpeed }

    func start() {
        guard manager.isDeviceMotionAvailable else {
            onStatus?("Head tracking unavailable. Connect AirPods Pro, Max, 3 or 4.")
            return
        }
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            guard let self else { return }
            if let error {
                self.onStatus?("Motion error: \(error.localizedDescription)")
                return
            }
            guard let m = motion else { return }
            // CoreMotion yaw is radians, positive when turning left (counter-clockwise).
            let raw = m.attitude.yaw * 180 / .pi
            let pitch = m.attitude.pitch * 180 / .pi
            self.lastRawYaw = raw
            if self.zeroYaw == nil {
                self.zeroYaw = raw
                self.onStatus?("Head tracking on. Face your screen and press Recenter.")
            }
            var yaw = -(raw - (self.zeroYaw ?? raw))
            if self.invert { yaw = -yaw }
            yaw = normalizeAngle(yaw)

            // Gestures want the raw signal: smoothing would blunt a quick nod.
            if let g = self.gestures.feed(time: m.timestamp, yaw: yaw, pitch: pitch) {
                self.onGesture?(g)
            }

            let prev = self.unwrappedYaw ?? yaw
            let unwrapped = prev + normalizeAngle(yaw - prev)
            self.unwrappedYaw = unwrapped
            let smoothYaw = self.yawFilter.filter(unwrapped, time: m.timestamp)
            let smoothPitch = self.pitchFilter.filter(pitch, time: m.timestamp)
            self.onYaw?(normalizeAngle(smoothYaw))
            self.onPitch?(smoothPitch)
        }
        onStatus?("Waiting for AirPods motion…")
    }

    /// Makes the current head direction the new "front".
    func recenter() {
        zeroYaw = lastRawYaw
        unwrappedYaw = nil
        yawFilter.reset()
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// One Euro filter: heavy smoothing when the head is still (kills jitter),
/// light smoothing when it moves fast (no lag on a real turn).
final class OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private let dCutoff = 1.0
    private var x: Double?
    private var dx: Double = 0
    private var t: Double?

    init(minCutoff: Double, beta: Double) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    func reset() { x = nil; t = nil; dx = 0 }

    func filter(_ value: Double, time: Double) -> Double {
        guard let px = x, let pt = t, time > pt else {
            x = value; t = time
            return value
        }
        let dt = min(time - pt, 0.2)
        let rawDx = (value - px) / dt
        dx = Self.lerp(dx, rawDx, Self.alpha(cutoff: dCutoff, dt: dt))
        let cutoff = minCutoff + beta * abs(dx)
        let out = Self.lerp(px, value, Self.alpha(cutoff: cutoff, dt: dt))
        x = out; t = time
        return out
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}

/// Spots nods (pitch down-up) and shakes (yaw left-right-left).
/// A gesture is a quick swing one way and a quick swing back, each big enough to be
/// deliberate. A plain turn toward an agent only swings one way, so it never counts.
final class GestureDetector {
    var sensitivity: Double = 1
    private(set) var yawSpeed: Double = 0
    private var pitchSpeed: Double = 0

    private struct Swing { let time: Double; let sign: Int; var peak: Double }
    private struct Sample { let time: Double; let yaw: Double; let pitch: Double }

    private var last: Sample?
    private var history: [Sample] = []
    private var yawSwings: [Swing] = []
    private var pitchSwings: [Swing] = []
    private var quietUntil: Double = 0

    // Before sensitivity: degrees per second, and degrees of travel.
    private let nodSpeed: Double = 60
    private let shakeSpeed: Double = 80
    private let nodSize: Double = 10
    private let shakeSize: Double = 18
    private let window: Double = 1.0
    private let cooldown: Double = 1.2

    func feed(time: Double, yaw: Double, pitch: Double) -> HeadGesture? {
        let sample = Sample(time: time, yaw: yaw, pitch: pitch)
        defer { last = sample }
        guard let last, time > last.time else { return nil }
        let dt = time - last.time
        guard dt < 0.2 else { history.removeAll(); return nil }

        // Light smoothing so sensor jitter doesn't register as swings.
        let a = 0.6
        yawSpeed = a * (normalizeAngle(yaw - last.yaw) / dt) + (1 - a) * yawSpeed
        pitchSpeed = a * ((pitch - last.pitch) / dt) + (1 - a) * pitchSpeed

        history.append(sample)
        history.removeAll { time - $0.time > window }

        guard time >= quietUntil else { return nil }

        let s = max(sensitivity, 0.1)
        record(&pitchSwings, speed: pitchSpeed, threshold: nodSpeed / s, time: time)
        record(&yawSwings, speed: yawSpeed, threshold: shakeSpeed / s, time: time)

        // How far the head actually travelled inside the window.
        let yaws = unwrap(history.map(\.yaw))
        let yawTravel = (yaws.max() ?? 0) - (yaws.min() ?? 0)
        let pitches = history.map(\.pitch)
        let pitchTravel = (pitches.max() ?? 0) - (pitches.min() ?? 0)

        // Shake: alternating yaw swings with real travel. Check before nod,
        // since heads bob a little while shaking.
        if yawSwings.count >= 3 || (yawSwings.count == 2 && yawTravel > shakeSize * 1.5 / s) {
            if yawTravel > shakeSize / s, yawTravel > pitchTravel * 1.3 { return fire(.shake, at: time) }
        }
        // Nod: down then up (or up then down), mostly vertical.
        if pitchSwings.count >= 2, pitchTravel > nodSize / s, pitchTravel > yawTravel * 1.3 {
            return fire(.nod, at: time)
        }
        return nil
    }

    private func record(_ swings: inout [Swing], speed: Double, threshold: Double, time: Double) {
        swings.removeAll { time - $0.time > window }
        guard abs(speed) > threshold else { return }
        let sign = speed > 0 ? 1 : -1
        if swings.last?.sign != sign { swings.append(Swing(time: time, sign: sign, peak: abs(speed))) }
    }

    private func unwrap(_ angles: [Double]) -> [Double] {
        guard var prev = angles.first else { return [] }
        return angles.map { a in
            prev = prev + normalizeAngle(a - prev)
            return prev
        }
    }

    private func fire(_ g: HeadGesture, at time: Double) -> HeadGesture {
        yawSwings.removeAll()
        pitchSwings.removeAll()
        history.removeAll()
        quietUntil = time + cooldown
        return g
    }
}
