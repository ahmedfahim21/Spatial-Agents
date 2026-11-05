import CoreMotion
import Foundation

/// Reads AirPods head orientation (AirPods Pro, Max, 3rd/4th gen; macOS 14+).
final class HeadTracker {
    private let manager = CMHeadphoneMotionManager()
    private var zeroYaw: Double?
    private var lastRawYaw: Double = 0

    /// Called on the main queue with yaw in degrees: 0 = calibrated front, positive = turned right.
    var onYaw: ((Double) -> Void)?
    var onStatus: ((String) -> Void)?
    var invert = false

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
            self.lastRawYaw = raw
            if self.zeroYaw == nil {
                self.zeroYaw = raw
                self.onStatus?("Head tracking on. Face your screen and press Recenter.")
            }
            var yaw = -(raw - (self.zeroYaw ?? raw))
            if self.invert { yaw = -yaw }
            self.onYaw?(normalizeAngle(yaw))
        }
        onStatus?("Waiting for AirPods motion…")
    }

    /// Makes the current head direction the new "front".
    func recenter() { zeroYaw = lastRawYaw }

    func stop() { manager.stopDeviceMotionUpdates() }
}
