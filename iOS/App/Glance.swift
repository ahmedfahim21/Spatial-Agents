import Foundation

/// Picks your left or right agent from which way you just turned your head, from wherever
/// you were facing. There's no forward to set or to drift: a quick turn left picks the left
/// agent, a quick turn right the right one. Only the movement counts, never where it ends up.
final class TurnPicker {
    /// Degrees a turn has to cover...
    var size: Double = 15
    /// ...within this many seconds, so slow drift and small talking movements never add up.
    var within: Double = 0.8
    private var recent: [(t: Double, yaw: Double)] = []
    private var last: Double?

    func reset() {
        recent = []
        last = nil
    }

    /// `yaw`: head yaw in degrees (+ = right), any frame, may wrap. Returns the side you
    /// turned toward, once per turn; nil otherwise.
    func feed(time: Double, yaw raw: Double) -> Zone? {
        let step = last.map { normalizeAngle(raw - $0) } ?? 0
        let yaw = (last ?? raw) + step
        last = yaw
        // The AirPods back after a pause, or a jump no head can make (their frame reset):
        // start over from here rather than read it as a turn.
        if let lt = recent.last?.t, time - lt > 0.5 || abs(step) > 45 { recent = [] }
        recent.append((time, yaw))
        recent.removeAll { time - $0.t > within }
        let yaws = recent.map(\.yaw)
        guard let lo = yaws.min(), let hi = yaws.max() else { return nil }
        let side: Zone
        if yaw - lo >= size {
            side = .right
        } else if hi - yaw >= size {
            side = .left
        } else {
            return nil
        }
        recent = [(time, yaw)]   // one pick per turn: the rest of it starts from here
        return side
    }
}
