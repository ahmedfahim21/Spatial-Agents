import AVFoundation
import Foundation
import Security
#if canImport(KokoroTTS)
import KokoroTTS
#endif

/// Something that turns text into mono audio. Engines stream: `onChunk` may be called
/// many times, so playback can start before the whole line is synthesized.
/// Engines must never play audio themselves; the spatial mixer places every chunk.
protocol VoiceEngine: AnyObject {
    var label: String { get }
    var isAvailable: Bool { get }
    /// Throws if nothing could be produced. `voiceIndex` picks a distinct voice per agent.
    func speak(_ text: String, voiceIndex: Int, onChunk: @escaping (AVAudioPCMBuffer) -> Void) async throws
}

struct VoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Tries each engine in order and falls back only if the previous one produced no audio,
/// so a line is never spoken twice.
final class VoiceRouter {
    /// Tried before everything else when set (the iPhone app's server-side voice).
    var primary: VoiceEngine?
    let elevenLabs = ElevenLabsVoice()
    let kokoro: VoiceEngine? = makeKokoroVoice()
    let apple = AppleVoice()

    /// Called on the main queue with which engine spoke (or why one failed).
    var onStatus: ((String) -> Void)?

    private var engines: [VoiceEngine] {
        [primary, elevenLabs, kokoro, apple].compactMap { $0 }.filter { $0.isAvailable }
    }

    /// Short lines ("Approved.") are cached per voice so they play instantly next time.
    private var cache: [String: [AVAudioPCMBuffer]] = [:]
    private let cacheLock = NSLock()

    var activeLabel: String { engines.first?.label ?? "None" }

    func speak(_ text: String, voiceIndex: Int, onChunk: @escaping (AVAudioPCMBuffer) -> Void) async {
        let cacheKey = "\(activeLabel)|\(voiceIndex)|\(text)"
        if text.count <= 40, let cached = cachedBuffers(cacheKey) {
            cached.forEach(onChunk)
            return
        }
        for engine in engines {
            var produced: [AVAudioPCMBuffer] = []
            do {
                try await engine.speak(text, voiceIndex: voiceIndex) { buf in
                    produced.append(buf)
                    onChunk(buf)
                }
                if text.count <= 40, !produced.isEmpty { store(cacheKey, produced) }
                report("Voice: \(engine.label)")
                return
            } catch {
                report("\(engine.label) failed: \(error.localizedDescription)")
                if !produced.isEmpty { return } // part of the line already played; don't repeat it
            }
        }
    }

    private func cachedBuffers(_ key: String) -> [AVAudioPCMBuffer]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[key]
    }

    private func store(_ key: String, _ buffers: [AVAudioPCMBuffer]) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache.count > 200 { cache.removeAll() }
        cache[key] = buffers
    }

    private func report(_ s: String) {
        DispatchQueue.main.async { self.onStatus?(s) }
    }
}

// MARK: - ElevenLabs

/// ElevenLabs streaming TTS: Flash v2.5, raw 16-bit PCM at 24 kHz, played as it arrives.
final class ElevenLabsVoice: VoiceEngine {
    let label = "ElevenLabs"
    static let sampleRate = 24000.0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    /// Voices from the user's ElevenLabs account, fetched once per key.
    private var voiceIds: [String] = []
    private var voiceIdsKey: String?
    private let lock = NSLock()

    private lazy var storedKey: String? = Keychain.read("elevenlabs")

    var apiKey: String? {
        lock.lock(); defer { lock.unlock() }
        if let k = storedKey, !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !k.isEmpty { return k }
        return nil
    }

    var hasStoredKey: Bool { lock.lock(); defer { lock.unlock() }; return !(storedKey ?? "").isEmpty }

    var isAvailable: Bool { apiKey != nil }

    func setKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if k.isEmpty { Keychain.delete("elevenlabs") } else { Keychain.write("elevenlabs", k) }
        lock.lock(); storedKey = k.isEmpty ? nil : k; voiceIds = []; voiceIdsKey = nil; lock.unlock()
    }

    func speak(_ text: String, voiceIndex: Int, onChunk: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        guard let key = apiKey else { throw VoiceError(message: "No ElevenLabs API key") }
        let voiceId = try await voice(for: voiceIndex, key: key)

        var comps = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)/stream")!
        comps.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": "eleven_flash_v2_5",
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse else { throw VoiceError(message: "No response") }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 2000 { break } }
            throw VoiceError(message: Self.describe(status: http.statusCode, body: body))
        }

        // Emit ~100 ms chunks so speech starts almost immediately.
        let chunkBytes = Int(Self.sampleRate * 0.1) * 2
        var pending = Data()
        pending.reserveCapacity(chunkBytes)
        for try await b in bytes {
            pending.append(b)
            if pending.count >= chunkBytes {
                if let buf = PCM16.buffer(pending, format: format) { onChunk(buf) }
                pending.removeAll(keepingCapacity: true)
            }
        }
        if pending.count >= 2, let buf = PCM16.buffer(pending, format: format) { onChunk(buf) }
    }

    /// Picks a distinct voice per agent from the account's voices (premade first, stable order).
    private func voice(for index: Int, key: String) async throws -> String {
        let cached = lock.withLock { voiceIdsKey == key ? voiceIds : [] }
        var ids = cached
        if ids.isEmpty {
            var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
            req.setValue(key, forHTTPHeaderField: "xi-api-key")
            req.timeoutInterval = 10
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw VoiceError(message: Self.describe(status: status, body: data)) }
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let voices = (obj?["voices"] as? [[String: Any]]) ?? []
            let sorted = voices.sorted { a, b in
                let pa = (a["category"] as? String) == "premade", pb = (b["category"] as? String) == "premade"
                if pa != pb { return pa }
                return ((a["name"] as? String) ?? "") < ((b["name"] as? String) ?? "")
            }
            ids = sorted.compactMap { $0["voice_id"] as? String }
            guard !ids.isEmpty else { throw VoiceError(message: "Your ElevenLabs account has no voices") }
            lock.withLock { voiceIds = ids; voiceIdsKey = key }
        }
        return ids[index % ids.count]
    }

    private static func describe(status: Int, body: Data) -> String {
        let detail = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
            .flatMap { ($0["detail"] as? [String: Any])?["message"] as? String ?? $0["detail"] as? String }
        switch status {
        case 401: return "ElevenLabs rejected the API key" + (detail.map { " (\($0))" } ?? "")
        case 402, 429: return "ElevenLabs quota or rate limit hit" + (detail.map { " (\($0))" } ?? "")
        default: return "ElevenLabs error \(status)" + (detail.map { ": \($0)" } ?? "")
        }
    }
}

/// Raw 16-bit little-endian PCM (what ElevenLabs streams) → Float32 buffers.
enum PCM16 {
    static func buffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let v = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                out[i] = Float(v) / 32768
            }
        }
        return buf
    }

    /// Streams `bytes` as ~100 ms buffers so playback starts almost immediately.
    static func stream(_ bytes: URLSession.AsyncBytes, sampleRate: Double, onChunk: (AVAudioPCMBuffer) -> Void) async throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let chunkBytes = Int(sampleRate * 0.1) * 2
        var pending = Data()
        pending.reserveCapacity(chunkBytes)
        for try await b in bytes {
            pending.append(b)
            if pending.count >= chunkBytes {
                if let buf = buffer(pending, format: format) { onChunk(buf) }
                pending.removeAll(keepingCapacity: true)
            }
        }
        if pending.count >= 2, let buf = buffer(pending, format: format) { onChunk(buf) }
    }
}

// MARK: - Apple (last resort)

/// Built-in macOS voices. Always available, so the app is never silent.
final class AppleVoice: VoiceEngine {
    let label = "Apple"
    var isAvailable: Bool { true }
    private var synths: [Int: AVSpeechSynthesizer] = [:]
    private let lock = NSLock()

    private lazy var english: [AVSpeechSynthesisVoice] = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language.hasPrefix("en") }
        .sorted { $0.quality.rawValue > $1.quality.rawValue }

    func speak(_ text: String, voiceIndex: Int, onChunk: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        let utterance = AVSpeechUtterance(string: text)
        if !english.isEmpty { utterance.voice = english[voiceIndex % english.count] }
        let synth = lock.withLock {
            let s = synths[voiceIndex] ?? AVSpeechSynthesizer()
            synths[voiceIndex] = s
            return s
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var done = false
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !done { done = true; cont.resume() }
                    return
                }
                onChunk(pcm)
            }
        }
    }
}

// MARK: - Kokoro (local neural, used when there's no ElevenLabs key or it fails)

#if canImport(KokoroTTS)
/// Kokoro-82M on the Neural Engine via kokoro-coreml. Downloads ~210 MB of models once.
final class KokoroVoice: VoiceEngine {
    let label = "Kokoro (local)"
    var isAvailable: Bool { true }
    private var loadTask: Task<KokoroTTS, Error>?
    private let lock = NSLock()

    init() {
        loadTask = Task { try await KokoroTTS.load(resources: .huggingFace()) }
    }

    func speak(_ text: String, voiceIndex: Int, onChunk: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        guard let loadTask else { throw VoiceError(message: "Kokoro not loaded") }
        let tts = try await loadTask.value
        // The starter bundle ships one voice; distinct voices per agent need the full bundle.
        let audio = try await tts.synthesize(text, voice: .afHeart)
        onChunk(try audio.makePCMBuffer())
    }
}

func makeKokoroVoice() -> VoiceEngine? { KokoroVoice() }
#else
func makeKokoroVoice() -> VoiceEngine? { nil }
#endif

// MARK: - Keychain

enum Keychain {
    private static let service = "xyz.agentsphere.app"

    static func read(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ account: String, _ value: String) {
        delete(account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
