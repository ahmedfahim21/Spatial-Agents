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
    /// Smoothed yaw in the tracker's fixed frame (no body-follow), for world-anchored things.
    var onFixedYaw: ((Double) -> Void)?
    var onGesture: ((HeadGesture) -> Void)?
    var onStatus: ((String) -> Void)?
    /// "walking", "re-centering" or "" — for the UI.
    var onFollowState: ((String) -> Void)?
    var invert = false { didSet { follower.reset() } }
    /// Agents travel with you (body-relative) instead of staying fixed in the room.
    var followMe: Bool {
        get { follower.enabled }
        set { follower.enabled = newValue; follower.reset() }
    }
    /// While true (talking to an agent, a permission waiting) the ring never re-centers.
    var isEngaged: () -> Bool = { false }
    private let follower = BodyFollower()
    private var lastFollowState = ""
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
            // Head direction relative to your body, so agents come with you when you turn or walk.
            let relative = self.follower.update(head: smoothYaw, time: m.timestamp,
                                                acceleration: m.userAcceleration, gravity: m.gravity, engaged: self.isEngaged())
            if self.follower.state != self.lastFollowState {
                self.lastFollowState = self.follower.state
                self.onFollowState?(self.follower.state)
            }
            self.onFixedYaw?(normalizeAngle(smoothYaw))
            self.onYaw?(relative)
            self.onPitch?(smoothPitch)
        }
        onStatus?("Waiting for AirPods motion…")
    }

    /// Makes the current head direction the new "front".
    func recenter() {
        zeroYaw = lastRawYaw
        unwrappedYaw = nil
        yawFilter.reset()
        follower.reset()
    }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// Estimates which way your body faces from head motion alone (AirPods can't see your body),
/// so the ring of agents can follow you:
/// - walking (step rhythm in the accelerometer): body follows the head within ~1 s;
/// - head held far (>45°) from the front for 6 s: you've turned, so re-center over ~1.5 s;
/// - otherwise a very slow pull (2 min) that also cancels compass drift.
/// Short glances never move it, and nothing moves while you're engaged with an agent.
final class BodyFollower {
    var enabled = true
    private(set) var state = ""
    private var bodyYaw: Double?
    private var lastTime: Double?
    private var offSince: Double?
    private var recentering = false
    private let walk = WalkDetector()

    func reset() {
        bodyYaw = nil
        offSince = nil
        recentering = false
    }

    /// `head` is unwrapped (continuous) yaw in degrees. Returns head yaw relative to the body.
    func update(head: Double, time: Double, acceleration a: CMAcceleration, gravity g: CMAcceleration, engaged: Bool) -> Double {
        let walking = walk.feed(time: time, acceleration: a, gravity: g)
        defer { lastTime = time }
        guard var body = bodyYaw, let last = lastTime else {
            bodyYaw = head
            return 0
        }
        let dt = min(max(time - last, 0), 0.2)
        let off = head - body

        if !enabled {
            state = ""
        } else if engaged {
            offSince = nil
            recentering = false
            state = ""
        } else if walking {
            body += off * min(1, dt / 0.8)
            recentering = false
            offSince = nil
            state = "walking"
        } else {
            if abs(off) > 45 {
                if offSince == nil { offSince = time }
                if let since = offSince, time - since > 6 { recentering = true }
            } else if !recentering {
                offSince = nil
            }
            if recentering {
                body += off * min(1, dt / 0.5)
                if abs(off) < 3 { recentering = false; offSince = nil }
                state = "re-centering"
            } else {
                body += off * dt / 120
                state = ""
            }
        }
        bodyYaw = body
        return normalizeAngle(head - body)
    }
}

/// Detects walking from the AirPods accelerometer: sustained (≥2 s) vertical bounce (each
/// step lifts and drops the head) well above what nods, shakes or fidgeting produce.
final class WalkDetector {
    private var samples: [(t: Double, m: Double)] = []
    private var activeSince: Double?
    private var quietSince: Double?
    private(set) var walking = false

    func feed(time: Double, acceleration a: CMAcceleration, gravity g: CMAcceleration) -> Bool {
        // Vertical component (signed), so the up-down step rhythm survives whatever the head's tilt.
        let gn = max((g.x * g.x + g.y * g.y + g.z * g.z).squareRoot(), 0.01)
        let m = (a.x * g.x + a.y * g.y + a.z * g.z) / gn
        samples.append((time, m))
        samples.removeAll { time - $0.t > 2 }
        guard samples.count > 10 else { return walking }
        let mean = samples.map(\.m).reduce(0, +) / Double(samples.count)
        let sd = (samples.map { ($0.m - mean) * ($0.m - mean) }.reduce(0, +) / Double(samples.count)).squareRoot()

        if sd > 0.06 {
            quietSince = nil
            if activeSince == nil { activeSince = time }
            if let s = activeSince, time - s >= 2 { walking = true }
        } else if sd < 0.03 {
            activeSince = nil
            if quietSince == nil { quietSince = time }
            if let q = quietSince, time - q >= 1.5 { walking = false }
        }
        return walking
    }
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
