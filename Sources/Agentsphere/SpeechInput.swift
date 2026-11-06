import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Speech

/// Transcribes your voice on-device (when supported).
///
/// The mic input stays open between utterances while hands-free is on; only the
/// recognition task starts and stops. Opening and closing the input reconfigures the
/// audio hardware, which forces every output engine to restart and stalls the UI.
final class SpeechInput {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    /// Rebuilt whenever the input (re)opens: AVAudioEngine caches the input format, and
    /// after switching devices a stale format crashes installTap.
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    /// Read from the audio tap thread.
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private let requestLock = NSLock()
    private var task: SFSpeechRecognitionTask?
    private var authorized = false
    private(set) var latest = ""
    /// Record from the Mac's built-in mic even if AirPods are the system input. An open
    /// AirPods mic drops them to call-quality audio, which ruins the spatial sound.
    var preferBuiltInMic = true
    private(set) var inputName = "Default input"

    /// Called on the main queue with the running transcript.
    var onPartial: ((String) -> Void)?

    /// Asks for mic + speech permission once, then starts a recognition. Completion gets an error message or nil.
    func begin(completion: @escaping (String?) -> Void) {
        if authorized {
            do { try startRecognition(); completion(nil) } catch { completion("Couldn't start listening: \(error.localizedDescription)") }
            return
        }
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
                    self.authorized = true
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

    /// Opens the mic once and keeps it open; buffers go to whichever recognition is current.
    private func ensureInput() throws {
        if let engine, engine.isRunning { return }
        shutdownInput()
        let e = AVAudioEngine()
        let input = e.inputNode
        if preferBuiltInMic, let unit = input.audioUnit, var mic = Self.builtInMic() {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &mic, UInt32(MemoryLayout<AudioDeviceID>.size))
            inputName = status == noErr ? "Built-in mic" : "Default input (couldn't select built-in mic)"
        } else {
            inputName = "Default input"
        }
        // The hardware's real format after the device switch; the tap must match it exactly.
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "Agentsphere", code: 2, userInfo: [NSLocalizedDescriptionKey: "No usable microphone input (\(inputName))"])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            guard let self else { return }
            let req = self.requestLock.withLock { self.currentRequest }
            req?.append(buffer)
        }
        e.prepare()
        try e.start()
        engine = e
        // If the input device changes underneath us, drop the engine; the next begin rebuilds it.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            print("Agentsphere: mic input configuration changed; reopening on next listen")
            self?.shutdownInput()
        }
        print("Agentsphere: mic open (\(inputName), \(Int(fmt.sampleRate)) Hz)")
    }

    private func startRecognition() throws {
        endRecognition()
        latest = ""
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "Agentsphere", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer unavailable"])
        }
        try ensureInput()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        requestLock.withLock { currentRequest = req }
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async {
                self?.latest = text
                self?.onPartial?(text)
            }
        }
    }

    /// Stops the current recognition and returns what was heard. The mic stays open.
    func finish() -> String {
        let text = latest
        endRecognition()
        return text
    }

    /// Closes the mic entirely (hands-free off, or after push-to-talk).
    func shutdown() {
        endRecognition()
        shutdownInput()
    }

    private func endRecognition() {
        let req = requestLock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            let r = currentRequest
            currentRequest = nil
            return r
        }
        req?.endAudio()
        task?.cancel()
        task = nil
    }

    private func shutdownInput() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
        print("Agentsphere: mic closed")
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

}
