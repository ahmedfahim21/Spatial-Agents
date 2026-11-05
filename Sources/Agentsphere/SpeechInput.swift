import AVFoundation
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
