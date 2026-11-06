import CoreMotion
import Foundation

/// Picks your left or right agent from a quick turn of the head, measured from wherever your
/// head was resting a moment ago, so it works whichever way you face, walk or sit.
///
/// - **Rest** is where your head settles. It soaks up small shifts and sensor drift, follows a
///   turn you hold (you've turned round), and follows at once when your phone turns too
///   (your body turned, e.g. a corner).
/// - **A glance** is a quick turn (inside about a second) of at least `threshold` degrees away
///   from rest that then holds still for a moment. Turning back toward rest ends it, and never
///   counts as a glance the other way. A shake never holds still, so it never lights a side.
final class GlanceTracker {
    enum Side { case left, right }

    /// Degrees from rest that count as a glance.
    var threshold: Double = 14
    /// A glance (or a slow turn) held this long, outside a conversation, means you've turned:
    /// rest moves there.
    var holdToFollow: Double = 4

    /// The side you're glancing at, once the glance has settled.
    private(set) var side: Side?
    /// Head direction relative to rest, degrees (+ = right).
    private(set) var offset: Double = 0

    private enum Mode { case resting, moving(Side, since: Double), glancing(since: Double), away(since: Double) }
    private var mode: Mode = .resting
    private var rest: Double?
    private var last: (t: Double, yaw: Double)?
    private var history: [(t: Double, yaw: Double)] = []
    /// Phone heading already credited to rest (see `creditPhone`).
    private var phoneMark: Double?

    func reset() {
        rest = nil
        last = nil
        history = []
        mode = .resting
        side = nil
        offset = 0
        phoneMark = nil
    }

    /// `yaw`: head direction in degrees (+ = right), any frame, may wrap.
    /// `phone`: the phone's heading at a time (degrees, + = right, continuous), nil when unknown.
    /// `engaged`: talking to an agent, so held turns don't move rest.
    /// Returns true when `side` changed.
    func feed(time: Double, yaw raw: Double, phone: (Double) -> Double?, engaged: Bool) -> Bool {
        let yaw = last.map { $0.yaw + normalizeAngle(raw - $0.yaw) } ?? raw
        let dt = min(max(time - (last?.t ?? time), 0), 0.2)
        last = (time, yaw)
        history.append((time, yaw))
        history.removeAll { time - $0.t > 1.2 }
        guard var r = rest else {
            rest = yaw
            phoneMark = phone(time)
            return false
        }
        let before = side
        var off = yaw - r
        let speed = recentSpeed()

        switch mode {
        case .resting:
            if abs(off) < threshold {
                // Small shifts and drift: rest drifts along with you.
                r += off * min(1, dt / 2)
                phoneMark = phone(time)
            } else if quick(r) {
                mode = .moving(off > 0 ? .right : .left, since: time)
                phoneMark = phone(time - 0.8)
            } else {
                mode = .away(since: time)
                phoneMark = phone(time - 0.8)
            }

        case .moving(let s, let since):
            if abs(off) < threshold * 0.6 || (off > 0) != (s == .right) {
                mode = .resting
            } else if speed < 40, time - since > 0.12 {
                mode = .glancing(since: time)
                side = s
            } else if time - since > 1.0 {
                mode = .away(since: time)
            }

        case .glancing(let since):
            if abs(off) < threshold * 0.6 {
                mode = .resting
                side = nil
            } else if (off > 0) != (side == .right) {
                // Straight across to the other side.
                mode = .moving(off > 0 ? .right : .left, since: time)
                side = nil
            } else if !engaged, time - since > holdToFollow {
                r = yaw
                mode = .resting
                side = nil
            }

        case .away(let since):
            if abs(off) < threshold * 0.6 {
                mode = .resting
            } else if !engaged, time - since > holdToFollow, speed < 20 {
                r = yaw
                mode = .resting
            }
        }

        // Turned with your phone: your body turned, so rest comes along.
        if case .resting = mode {} else if let now = phone(time), let mark = phoneMark {
            let turned = now - mark
            if abs(turned) > 15, (turned > 0) == (off > 0) {
                // Never past your head: a body that turned further than the head isn't a glance back.
                r += turned > 0 ? min(turned, off) : max(turned, off)
                phoneMark = now
                off = yaw - r
                if abs(off) < threshold * 0.6 {
                    mode = .resting
                    side = nil
                }
            }
        }

        rest = r
        offset = normalizeAngle(yaw - r)
        return side != before
    }

    /// The head left rest within the last second (rather than creeping away).
    private func quick(_ r: Double) -> Bool {
        guard let first = history.first(where: { last!.t - $0.t <= 1.0 }) else { return false }
        return abs(first.yaw - r) < threshold * 0.5
    }

    /// Degrees per second over the last ~0.15 s.
    private func recentSpeed() -> Double {
        guard let now = last, let then = history.last(where: { now.t - $0.t >= 0.15 }), now.t > then.t else { return 0 }
        return abs(now.yaw - then.yaw) / (now.t - then.t)
    }
}

/// Which way the phone has turned around the vertical, wherever it is: flat in your hand or
/// upright in a pocket. Turning about gravity is the same whatever the phone's pose, so a
/// phone that travels with you turns when your body does.
final class PhoneTurn {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var yaw: Double = 0
    private var lastTime: Double?
    private var history: [(t: Double, yaw: Double)] = []

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1 / 30
        queue.maxConcurrentOperationCount = 1
        manager.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            guard let self, let m else { return }
            let g = m.gravity, w = m.rotationRate
            let gn = max((g.x * g.x + g.y * g.y + g.z * g.z).squareRoot(), 0.01)
            // Rotation about "down": + is clockwise seen from above, i.e. turning right.
            let rate = (w.x * g.x + w.y * g.y + w.z * g.z) / gn * 180 / .pi
            self.lock.withLock {
                if let lt = self.lastTime { self.yaw += rate * min(max(m.timestamp - lt, 0), 0.2) }
                self.lastTime = m.timestamp
                self.history.append((m.timestamp, self.yaw))
                self.history.removeAll { m.timestamp - $0.t > 3 }
            }
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    /// Heading (degrees, + = right, continuous) at a time on the motion clock, if known.
    func yaw(at time: Double) -> Double? {
        lock.withLock {
            guard let newest = history.last, time <= newest.t + 0.5, let oldest = history.first, time >= oldest.t - 0.1 else { return nil }
            return history.last(where: { $0.t <= time })?.yaw ?? oldest.yaw
        }
    }
}
