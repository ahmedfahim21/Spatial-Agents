import AVFoundation
import Foundation
import Speech
#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

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
    /// false (default): the system input, i.e. the AirPods mic, so you can talk from anywhere.
    /// true: the Mac's built-in mic, which keeps AirPods in stereo but only hears you near the Mac.
    /// While the AirPods mic is open macOS switches them to mono headset mode.
    var preferBuiltInMic = false
    /// Keeping the input open avoids hardware reconfiguration, but an open AirPods mic keeps
    /// them in mono headset mode, so only the built-in mic stays open between utterances.
    var keepsInputOpen: Bool {
        #if os(iOS)
        // iOS 26 full-bandwidth AirPods audio keeps playback in stereo with the mic open.
        return AudioSession.highQualityMic || preferBuiltInMic
        #else
        return preferBuiltInMic
        #endif
    }
    private var openedAt = Date.distantPast
    /// The mic input is open (and, for AirPods, holding them in headset mode).
    var isInputOpen: Bool { engine != nil }
    private(set) var inputName = "Default input"

    /// Words likely to be said (e.g. agent names), so recognition favours them.
    var hints: [String] = []
    /// Called on the main queue with the running transcript.
    var onPartial: ((String) -> Void)?

    /// Also keep each utterance's audio (16 kHz mono 16-bit), for transcribing on a server.
    var recordsAudio = false
    private static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    /// About 60 s; longer utterances keep only the start (guarded by requestLock).
    private static let maxRecorded = 1_920_000
    private var recorded = Data()
    private var recording = false

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
        #if os(macOS)
        if preferBuiltInMic, let unit = input.audioUnit, var mic = Self.builtInMic() {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &mic, UInt32(MemoryLayout<AudioDeviceID>.size))
            inputName = status == noErr ? "Built-in mic" : "Default input (couldn't select built-in mic)"
        } else {
            inputName = "Default input"
        }
        #else
        AudioSession.preferBuiltInMic(preferBuiltInMic)
        inputName = AudioSession.inputName
        #endif
        // The hardware's real format after the device switch; the tap must match it exactly.
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            throw NSError(domain: "Agentsphere", code: 2, userInfo: [NSLocalizedDescriptionKey: "No usable microphone input (\(inputName))"])
        }
        // Lives with this tap: a reopened input gets a new one for its new format.
        let converter = AVAudioConverter(from: fmt, to: Self.pcmFormat)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            guard let self else { return }
            let (req, rec) = self.requestLock.withLock { (self.currentRequest, self.recording) }
            req?.append(buffer)
            if rec, let converter, let pcm = Self.pcm16(buffer, converter) {
                self.requestLock.withLock {
                    if self.recording, self.recorded.count < Self.maxRecorded { self.recorded.append(pcm) }
                }
            }
        }
        e.prepare()
        try e.start()
        engine = e
        // Opening the AirPods mic flips them into headset mode, which reconfigures this very
        // engine. Reopen the input so an active recognition keeps getting audio.
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            guard let self else { return }
            print("Agentsphere: mic input configuration changed; reopening")
            self.shutdownInput()
            let listening = self.requestLock.withLock { self.currentRequest != nil }
            if listening {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    do { try self.ensureInput() } catch { print("Agentsphere: mic reopen failed: \(error)") }
                }
            }
        }
        openedAt = Date()
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
        req.contextualStrings = hints
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        requestLock.withLock {
            currentRequest = req
            recorded = Data()
            recording = recordsAudio
        }
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

    /// Like finish(), plus the utterance's audio as a WAV (nil unless recordsAudio).
    func finishWithAudio() -> (text: String, wav: Data?) {
        let text = finish()
        let pcm = requestLock.withLock { () -> Data in
            let d = recorded
            recorded = Data()
            return d
        }
        return (text, pcm.isEmpty ? nil : Self.wav(pcm, sampleRate: 16000))
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
            recording = false
            return r
        }
        req?.endAudio()
        task?.cancel()
        task = nil
    }

    /// One mic buffer, resampled to 16 kHz mono 16-bit. The converter keeps its state between
    /// buffers, so consecutive buffers join up seamlessly.
    private static func pcm16(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * pcmFormat.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0, let samples = out.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(out.frameLength) * 2)
    }

    /// 16-bit mono PCM wrapped in a WAV header.
    static func wav(_ pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        d.append(pcm)
        return d
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

    #if os(macOS)
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
    #endif
}
