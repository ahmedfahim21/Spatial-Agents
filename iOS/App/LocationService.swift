import CoreLocation
import CoreMotion
import Foundation
import Observation

/// GPS position and compass heading, or a simulated position in demo mode.
@Observable @MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private(set) var coordinate: CLLocationCoordinate2D? {
        didSet {
            if hasFix != (coordinate != nil) { hasFix = coordinate != nil }
            onMove?()
        }
    }
    /// Whether there's a position at all. Views that only care about this read it instead of
    /// `coordinate`, so they don't redraw on every GPS update.
    private(set) var hasFix = false
    /// Horizontal accuracy in metres (smaller is better).
    private(set) var accuracy: Double = .infinity
    /// Phone heading, degrees from true north.
    private(set) var heading: Double? { didSet { onHeading?() } }
    private(set) var headingAccuracy: Double = .infinity
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// The fix has stayed rough (worse than 20 m) for 10 s: you're probably inside. Distances
    /// are then shown as words, never falsely precise numbers.
    private(set) var indoors = false
    /// The phone's motion says you're standing still: the position holds instead of drifting.
    private(set) var stationary = false
    @ObservationIgnored private var roughSince: Date?
    @ObservationIgnored private let activity = CMMotionActivityManager()
    @ObservationIgnored private var watchingActivity = false

    /// Demo mode: pretend to be here instead of using GPS.
    var simulated: CLLocationCoordinate2D? {
        didSet { if let s = simulated { coordinate = s; accuracy = 5; indoors = false } }
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
        // Precise Location off: finding an agent a few metres away needs it, so ask for it
        // for this session.
        if isAuthorized, manager.accuracyAuthorization == .reducedAccuracy {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "FindAgents")
        }
        if !watchingActivity, CMMotionActivityManager.isActivityAvailable() {
            watchingActivity = true
            activity.startActivityUpdates(to: .main) { [weak self] a in
                guard let a else { return }
                MainActor.assumeIsolated {
                    self?.stationary = a.stationary && !a.walking && !a.running && !a.cycling
                        && !a.automotive && a.confidence != .low
                }
            }
        }
    }

    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard self.simulated == nil else { return }
            for l in locations {
                self.noteRoughness(l.horizontalAccuracy)
                guard let fix = self.filter.add(l) else { continue }
                // Standing still: hold the position (so distances don't drift) unless the
                // new fix is clearly better than the one we have.
                if self.stationary, self.coordinate != nil, l.horizontalAccuracy > self.accuracy - 3 { continue }
                self.coordinate = fix
                self.accuracy = l.horizontalAccuracy
            }
        }
    }

    private func noteRoughness(_ acc: Double) {
        guard acc >= 0 else { return }
        if acc > 20 {
            if roughSince == nil { roughSince = Date() }
            if let since = roughSince, Date().timeIntervalSince(since) > 10, !indoors { indoors = true }
        } else if acc <= 15 {
            roughSince = nil
            if indoors { indoors = false }
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
