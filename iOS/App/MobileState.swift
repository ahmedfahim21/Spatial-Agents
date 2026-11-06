import AVFoundation
import Combine
import SwiftUI

/// The phone app's brain: head tracking, spatial audio and (later) agents and location.
@MainActor
final class MobileState: ObservableObject {
    let head = HeadMotion()
    let voices = VoiceRouter()
    let audio: SpatialAudio
    let speech = SpeechInput()
    private let tracker = HeadTracker()

    @Published var trackingStatus = "Starting…"
    @Published var lastGesture: HeadGesture?
    @Published var route = ""
    @Published var highQualityMic = false

    init() {
        AudioSession.configure()
        audio = SpatialAudio(voices: voices)
        tracker.onStatus = { [weak self] s in self?.trackingStatus = s }
        tracker.onYaw = { [weak self] y in
            self?.head.yaw = y
            self?.audio.headYaw = y
        }
        tracker.onPitch = { [weak self] p in self?.head.pitch = p }
        tracker.onGesture = { [weak self] g in self?.lastGesture = g }
        tracker.start()
        refreshRoute()
    }

    func recenter() { tracker.recenter() }

    func refreshRoute() {
        route = AudioSession.routeDescription
        highQualityMic = AudioSession.highQualityMic
    }

    // MARK: - Spatial test

    private let testId = UUID()
    private var testRegistered = false

    /// Plays a voice from the front, right, behind and left, so you can check placement.
    func runSpatialTest() {
        if !testRegistered {
            audio.register(id: testId, azimuth: 0, voiceIndex: 0)
            testRegistered = true
        }
        let spots: [(Double, String)] = [(0, "In front of you."), (90, "On your right."), (180, "Behind you."), (-90, "On your left.")]
        Task {
            for (az, line) in spots {
                audio.setAzimuth(id: testId, azimuth: az)
                audio.speak(line, from: testId, prelude: .chime)
                try? await Task.sleep(nanoseconds: 2_600_000_000)
            }
            audio.setAzimuth(id: testId, azimuth: 0)
        }
    }
}
