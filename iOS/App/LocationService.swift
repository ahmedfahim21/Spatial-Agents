import CoreLocation
import Foundation
import Observation

/// GPS position and compass heading, or a simulated position in demo mode.
@Observable @MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D? { didSet { onMove?() } }
    /// Horizontal accuracy in metres (smaller is better).
    private(set) var accuracy: Double = .infinity
    /// Phone heading, degrees from true north.
    private(set) var heading: Double? { didSet { onHeading?() } }
    private(set) var headingAccuracy: Double = .infinity
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    /// Demo mode: pretend to be here instead of using GPS.
    var simulated: CLLocationCoordinate2D? {
        didSet { if let s = simulated { coordinate = s; accuracy = 5 } }
    }

    @ObservationIgnored var onMove: (() -> Void)?
    @ObservationIgnored var onHeading: (() -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var filter = PositionFilter()

    /// Indoors or a poor fix: turn on the safeguards (wider arrival, direction lock).
    var isPoorFix: Bool { simulated == nil && accuracy > 15 }

    override init() {
        super.init()
        manager.delegate = self
        // Best-for-navigation also fuses Wi-Fi and Bluetooth indoors. The filter wants every
        // sample (it weighs them by accuracy), so no distance filter.
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 1
        manager.activityType = .fitness
        authorization = manager.authorizationStatus
    }

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard self.simulated == nil else { return }
            for l in locations {
                guard let fix = self.filter.add(l) else { continue }
                self.coordinate = fix
                self.accuracy = l.horizontalAccuracy
            }
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
