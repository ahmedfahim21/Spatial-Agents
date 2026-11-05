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

    /// Called on the main queue with yaw in degrees: 0 = calibrated front, positive = turned right.
    var onYaw: ((Double) -> Void)?
    /// Called on the main queue with pitch in degrees: positive = looking up.
    var onPitch: ((Double) -> Void)?
    var onGesture: ((HeadGesture) -> Void)?
    var onStatus: ((String) -> Void)?
    var invert = false
    /// 0.5 (stiff) ... 2 (twitchy). Scales the angular speed a nod or shake needs.
    var sensitivity: Double {
        get { gestures.sensitivity }
        set { gestures.sensitivity = newValue }
    }

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
            self.onYaw?(yaw)
            self.onPitch?(pitch)
            if let g = self.gestures.feed(time: m.timestamp, yaw: yaw, pitch: pitch) {
                self.onGesture?(g)
            }
        }
        onStatus?("Waiting for AirPods motion…")
    }

    /// Makes the current head direction the new "front".
    func recenter() { zeroYaw = lastRawYaw }

    func stop() { manager.stopDeviceMotionUpdates() }
}

/// Spots nods (pitch down-up) and shakes (yaw left-right-left) from angular velocity.
/// A gesture is a quick swing one way followed by a quick swing back; a plain turn
/// toward an agent only swings one way, so it never counts.
final class GestureDetector {
    var sensitivity: Double = 1

    private struct Swing { let time: Double; let sign: Int }

    private var last: (time: Double, yaw: Double, pitch: Double)?
    private var yawSpeed: Double = 0
    private var pitchSpeed: Double = 0
    private var yawSwings: [Swing] = []
    private var pitchSwings: [Swing] = []
    private var quietUntil: Double = 0

    // Degrees per second, before sensitivity.
    private let nodSpeed: Double = 70
    private let shakeSpeed: Double = 90
    private let window: Double = 0.9
    private let cooldown: Double = 1.2

    func feed(time: Double, yaw: Double, pitch: Double) -> HeadGesture? {
        defer { last = (time, yaw, pitch) }
        guard let last, time > last.time else { return nil }
        let dt = time - last.time
        guard dt < 0.2 else { return nil }

        // Light smoothing so sensor jitter doesn't register as swings.
        let a = 0.5
        yawSpeed = a * (normalizeAngle(yaw - last.yaw) / dt) + (1 - a) * yawSpeed
        pitchSpeed = a * ((pitch - last.pitch) / dt) + (1 - a) * pitchSpeed

        guard time >= quietUntil else { return nil }

        let nodT = nodSpeed / sensitivity
        let shakeT = shakeSpeed / sensitivity
        record(&pitchSwings, speed: pitchSpeed, threshold: nodT, time: time)
        record(&yawSwings, speed: yawSpeed, threshold: shakeT, time: time)

        // Shake: three alternating yaw swings (left-right-left), or two big ones.
        // Head bob while shaking is common, so check shake before nod.
        if yawSwings.count >= 3 || (yawSwings.count == 2 && abs(yawSpeed) > shakeT * 1.6) {
            return fire(.shake, at: time)
        }
        // Nod: down then up (or up then down) while not turning much.
        if pitchSwings.count >= 2, abs(yawSpeed) < shakeT {
            return fire(.nod, at: time)
        }
        return nil
    }

    private func record(_ swings: inout [Swing], speed: Double, threshold: Double, time: Double) {
        swings.removeAll { time - $0.time > window }
        guard abs(speed) > threshold else { return }
        let sign = speed > 0 ? 1 : -1
        if swings.last?.sign != sign { swings.append(Swing(time: time, sign: sign)) }
    }

    private func fire(_ g: HeadGesture, at time: Double) -> HeadGesture {
        yawSwings.removeAll()
        pitchSwings.removeAll()
        quietUntil = time + cooldown
        return g
    }
}
