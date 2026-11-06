import AVFoundation
import Foundation

/// iOS audio session: play and record at once, preferring iOS 26's full-bandwidth AirPods
/// mode (stereo playback with the mic open) and falling back to headset mode.
/// On macOS there is no session; these are no-ops.
enum AudioSession {
    #if os(iOS)
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.bluetoothHighQualityRecording, .allowBluetoothHFP, .allowBluetoothA2DP,
                                              // Without headphones, play from the loudspeaker, not the earpiece.
                                              .defaultToSpeaker])
            try session.setPrefersNoInterruptionsFromSystemAlerts(true)
            try session.setActive(true)
        } catch {
            print("Agentsphere: audio session error: \(error)")
        }
        print("Agentsphere: audio route \(routeDescription), high-quality mic: \(highQualityMic)")
    }

    /// Playback only, for before the user has been asked about the microphone: activating a
    /// recording session would pop the mic prompt with no context.
    static func configurePlaybackOnly() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    /// Full-bandwidth AirPods audio is active, so the mic can stay open without going mono.
    static var highQualityMic: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains { $0.bluetoothMicrophoneExtension?.highQualityRecording.isEnabled == true }
    }

    static var inputName: String {
        AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "Default input"
    }

    static var routeDescription: String {
        let r = AVAudioSession.sharedInstance().currentRoute
        let ins = r.inputs.map(\.portName).joined(separator: ", ")
        let outs = r.outputs.map(\.portName).joined(separator: ", ")
        return "in: \(ins.isEmpty ? "-" : ins) / out: \(outs.isEmpty ? "-" : outs)"
    }

    static func preferBuiltInMic(_ builtIn: Bool) {
        let session = AVAudioSession.sharedInstance()
        let port = builtIn ? session.availableInputs?.first { $0.portType == .builtInMic } : nil
        try? session.setPreferredInput(port)
    }
    #else
    static func configure() {}
    static func configurePlaybackOnly() {}
    static var highQualityMic: Bool { false }
    #endif
}
