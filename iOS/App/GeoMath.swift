import CoreLocation
import Foundation

/// Distance and direction between coordinates, and the Find-mode feedback curves.
enum GeoMath {
    static let earthRadius = 6_371_000.0

    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dφ = (b.latitude - a.latitude) * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from true north (0...360).
    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let φ1 = a.latitude * .pi / 180, φ2 = b.latitude * .pi / 180
        let dλ = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        let θ = atan2(y, x) * 180 / .pi
        return (θ + 360).truncatingRemainder(dividingBy: 360)
    }

    /// A point `metres` away from `a` along `bearing` (used by demo mode).
    static func offset(_ a: CLLocationCoordinate2D, metres: Double, bearing: Double) -> CLLocationCoordinate2D {
        let δ = metres / earthRadius, θ = bearing * .pi / 180
        let φ1 = a.latitude * .pi / 180, λ1 = a.longitude * .pi / 180
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        return CLLocationCoordinate2D(latitude: φ2 * 180 / .pi, longitude: λ2 * 180 / .pi)
    }

    /// You've arrived when inside the agent's radius, padded by GPS uncertainty
    /// (capped, so a terrible fix doesn't "arrive" you from across the street).
    static func arrivalRadius(agentRadius: Double, accuracy: Double) -> Double {
        agentRadius + min(max(accuracy, 0), 30)
    }

    /// Find-mode haptics: closer = faster and stronger. Distance is metres beyond arrival.
    static func hapticPulse(distance: Double) -> (interval: Double, intensity: Double, sharpness: Double) {
        let t = min(max(distance, 0), 250) / 250          // 0 near ... 1 far
        return (interval: 0.22 + t * 1.6, intensity: 1 - t * 0.65, sharpness: 0.75 - t * 0.45)
    }

    /// Beacon loudness, 0.2 far ... 1 at the agent.
    static func beaconGain(distance: Double) -> Double {
        0.2 + 0.8 * (1 - min(max(distance, 0), 250) / 250)
    }

    /// A distance no more precise than we know it. Within the fix's accuracy it's "Nearby";
    /// beyond, the nearest 5 m (under 20 m), 10 m (under 100 m), 50 m, or tenth of a km.
    static func describe(distance d: Double, accuracy: Double = 0) -> String {
        if d < max(accuracy, 0) + 5 { return "Nearby" }
        let step: Double = d < 20 ? 5 : d < 100 ? 10 : 50
        let r = max(step, (d / step).rounded() * step)
        if r >= 1000 { return String(format: "%.1f km", d / 1000) }
        return "\(Int(r)) m"
    }

    /// The same, for a voice to say: "about 50 metres", "close by".
    static func spoken(distance d: Double, accuracy: Double = 0) -> String {
        let s = describe(distance: d, accuracy: accuracy)
        if s == "Nearby" { return "close by" }
        return "about " + s.replacingOccurrences(of: " km", with: " kilometres").replacingOccurrences(of: " m", with: " metres")
    }
}
