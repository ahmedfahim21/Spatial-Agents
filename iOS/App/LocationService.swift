import Combine
import CoreLocation
import Foundation

/// GPS position and compass heading, or a simulated position in demo mode.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    /// Horizontal accuracy in metres (smaller is better).
    @Published private(set) var accuracy: Double = .infinity
    /// Phone heading, degrees from true north.
    @Published private(set) var heading: Double?
    @Published private(set) var headingAccuracy: Double = .infinity
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    /// Demo mode: pretend to be here instead of using GPS.
    @Published var simulated: CLLocationCoordinate2D? {
        didSet { if let s = simulated { coordinate = s; accuracy = 5 } }
    }

    private let manager = CLLocationManager()

    /// Indoors or a poor fix: turn on the safeguards (wider arrival, direction lock).
    var isPoorFix: Bool { simulated == nil && accuracy > 15 }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 1
        manager.headingFilter = 1
        manager.activityType = .fitness
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        Task { @MainActor in
            guard self.simulated == nil else { return }
            self.coordinate = l.coordinate
            self.accuracy = l.horizontalAccuracy
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        guard h.headingAccuracy >= 0 else { return }
        let value = h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading
        Task { @MainActor in
            self.heading = value
            self.headingAccuracy = h.headingAccuracy
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let status = m.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.start() }
        }
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool { true }
}
