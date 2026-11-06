import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Speech

/// Push-to-talk: transcribes your voice on-device (when supported).
final class SpeechInput {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private(set) var latest = ""
    /// Record from the Mac's built-in mic even if AirPods are the system input. An open
    /// AirPods mic drops them to call-quality audio, which ruins the spatial sound.
    var preferBuiltInMic = true
    private(set) var inputName = "Default input"

    /// Called on the main queue with the running transcript.
    var onPartial: ((String) -> Void)?

    /// Asks for mic + speech permission, then starts listening. Completion gets an error message or nil.
    func begin(completion: @escaping (String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { micOK in
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    guard micOK else {
                        completion("Microphone access denied. Allow it in System Settings › Privacy & Security › Microphone.")
                        return
                    }
                    guard status == .authorized else {
                        completion("Speech recognition not allowed. Allow it in System Settings › Privacy & Security › Speech Recognition.")
                        return
                    }
                    do {
                        try self.startRecognition()
                        completion(nil)
                    } catch {
                        completion("Couldn't start listening: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    private func startRecognition() throws {
        cleanup()
        latest = ""
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Agentsphere", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req

        let input = engine.inputNode
        if preferBuiltInMic, let unit = input.audioUnit, var mic = Self.builtInMic() {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &mic, UInt32(MemoryLayout<AudioDeviceID>.size))
            inputName = status == noErr ? "Built-in mic" : "Default input (couldn't select built-in mic)"
        } else {
            inputName = "Default input"
        }
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in req.append(buffer) }
        tapInstalled = true
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async {
                self?.latest = text
                self?.onPartial?(text)
            }
        }
    }

    /// Stops listening and returns what was heard.
    func finish() -> String {
        let text = latest
        cleanup()
        return text
    }

    /// The Mac's built-in microphone, if it has one.
    static func builtInMic() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }
        for id in ids {
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            var taddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                   mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &taddr, 0, nil, &tsize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                   mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var ssize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(id, &saddr, 0, nil, &ssize) == noErr, ssize > 0 { return id }
        }
        return nil
    }

    private func cleanup() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }
}
