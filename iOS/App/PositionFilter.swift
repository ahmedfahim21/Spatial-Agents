import CoreLocation
import Foundation

/// Steadies GPS indoors, where fixes bounce tens of metres off walls.
///
/// 1. Drops stale (cached) fixes and invalid ones.
/// 2. Drops a fix much worse than a recent one, and jumps faster than a person moves,
///    unless they keep coming (then it's us that's wrong, so we follow).
/// 3. Smooths with a small Kalman filter: precise fixes pull hard, rough ones barely move
///    the position. This is an accuracy-weighted moving average that adapts to the fix.
struct PositionFilter {
    /// How fast a walking person's position can drift, m²/s (process noise).
    var walkingNoise = 2.0
    /// Faster than this (m/s) is a bounce, not a person walking or jogging.
    var maxSpeed = 8.0

    private var origin: CLLocationCoordinate2D?
    private var east = 0.0, north = 0.0     // metres from origin
    private var variance = 0.0              // m²
    private var lastTime: Date?
    private var lastAccepted: CLLocation?
    private var rejectedInARow = 0

    /// Returns the smoothed position, or nil if this fix was dropped.
    mutating func add(_ l: CLLocation) -> CLLocationCoordinate2D? {
        let acc = l.horizontalAccuracy
        guard acc >= 0, abs(l.timestamp.timeIntervalSinceNow) < 5 else { return nil }

        guard let o = origin, let t = lastTime, let prev = lastAccepted else {
            origin = l.coordinate; east = 0; north = 0
            variance = acc * acc; lastTime = l.timestamp; lastAccepted = l
            return l.coordinate
        }

        let dt = max(0.05, l.timestamp.timeIntervalSince(t))
        // Moving: let the position move more freely (Core Location's speed, when it has one).
        let q = l.speed > 0.5 ? max(walkingNoise, l.speed * l.speed * 2) : walkingNoise
        let predicted = variance + q * dt
        let jump = l.distance(from: prev)
        let recentGood = sqrt(predicted)
        let muchWorse = acc > 25 && acc > 2.5 * recentGood
        let tooFast = jump > acc + prev.horizontalAccuracy && jump / dt > maxSpeed
        if (muchWorse || tooFast) && rejectedInARow < 4 {
            rejectedInARow += 1
            return nil
        }
        rejectedInARow = 0

        // Kalman update, same gain for both axes (accuracy is a circle).
        let (e, n) = Self.metres(from: o, to: l.coordinate)
        // Good outdoor fixes are already clean: follow them closely so Find mode doesn't lag.
        let gain = max(predicted / (predicted + acc * acc), acc <= 8 ? 0.6 : 0)
        east += gain * (e - east)
        north += gain * (n - north)
        variance = (1 - gain) * predicted
        lastTime = l.timestamp
        lastAccepted = l
        return Self.coordinate(from: o, east: east, north: north)
    }

    mutating func reset() { self = PositionFilter() }

    // Local flat-earth projection; fine over the few km we care about.
    private static func metres(from o: CLLocationCoordinate2D, to c: CLLocationCoordinate2D) -> (Double, Double) {
        let r = 6_371_000.0
        let n = (c.latitude - o.latitude) * .pi / 180 * r
        let e = (c.longitude - o.longitude) * .pi / 180 * r * cos(o.latitude * .pi / 180)
        return (e, n)
    }

    private static func coordinate(from o: CLLocationCoordinate2D, east: Double, north: Double) -> CLLocationCoordinate2D {
        let r = 6_371_000.0
        return CLLocationCoordinate2D(
            latitude: o.latitude + north / r * 180 / .pi,
            longitude: o.longitude + east / (r * cos(o.latitude * .pi / 180)) * 180 / .pi)
    }
}
