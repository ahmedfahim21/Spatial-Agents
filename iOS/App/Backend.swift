import AVFoundation
import Foundation

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to Supabase: anonymous sign-in, agents, nearby search, chat and voice.
/// Plain URLSession (no SDK). Thread-safe; call from anywhere.
final class Backend: @unchecked Sendable {
    static let shared = Backend()

    private struct Session: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var userId: String
    }

    private let lock = NSLock()
    private var session: Session?
    /// False once the database has told us it has no `shape` column, so later saves don't
    /// pay for a failed round trip first.
    private var shapeColumn = true
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init() {
        if let raw = Keychain.read("supabase-session"), let data = raw.data(using: .utf8),
           let s = try? JSONDecoder().decode(Session.self, from: data) {
            session = s
        }
    }

    var userId: String? { lock.withLock { session?.userId } }

    // MARK: - Auth

    /// A valid access token, signing in anonymously or refreshing as needed.
    func token() async throws -> String {
        guard Config.isConfigured else { throw BackendError(message: "Supabase isn't configured yet (Config.swift).") }
        if let s = lock.withLock({ session }) {
            if s.expiresAt.timeIntervalSinceNow > 60 { return s.accessToken }
            if let refreshed = try? await authRequest(path: "token?grant_type=refresh_token", body: ["refresh_token": s.refreshToken]) {
                return refreshed.accessToken
            }
        }
        return try await authRequest(path: "signup", body: [:]).accessToken
    }

    private func authRequest(path: String, body: [String: String]) async throws -> Session {
        var req = URLRequest(url: URL(string: Config.supabaseURL.absoluteString + "/auth/v1/" + path)!)
        req.httpMethod = "POST"
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String,
              let user = (obj["user"] as? [String: Any])?["id"] as? String else {
            throw BackendError(message: "Unexpected sign-in response")
        }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        let s = Session(accessToken: access, refreshToken: refresh, expiresAt: Date().addingTimeInterval(expiresIn), userId: user)
        lock.withLock { session = s }
        if let d = try? JSONEncoder().encode(s) { Keychain.write("supabase-session", String(decoding: d, as: UTF8.self)) }
        return s
    }

    // MARK: - Agents

    func nearby(lat: Double, lng: Double, km: Double = 5) async throws -> [Agent] {
        let data = try await rest("rpc/nearby_agents", method: "POST",
                                  json: ["p_lat": lat, "p_lng": lng, "p_km": km])
        return try decoder.decode([Agent].self, from: data)
    }

    /// Agents you own (with their context), newest first.
    func myAgents() async throws -> [Agent] {
        let data = try await rest("agents?select=*&order=created_at.desc", method: "GET")
        return try decoder.decode([Agent].self, from: data)
    }

    func create(_ agent: NewAgent) async throws -> Agent {
        var agent = agent
        if !lock.withLock({ shapeColumn }) { agent.shape = nil }
        let data: Data
        do {
            data = try await rest("agents", method: "POST", body: try encoder.encode(agent), prefer: "return=representation")
        } catch let error as BackendError where error.message.contains("'shape'") && agent.shape != nil {
            // The database predates agent shapes (migration 20261106120000 not applied yet):
            // save without it; the app derives a stable shape from the id.
            lock.withLock { shapeColumn = false }
            agent.shape = nil
            data = try await rest("agents", method: "POST", body: try encoder.encode(agent), prefer: "return=representation")
        }
        guard let created = try decoder.decode([Agent].self, from: data).first else {
            throw BackendError(message: "The agent wasn't saved")
        }
        return created
    }

    func delete(_ id: UUID) async throws {
        _ = try await rest("agents?id=eq.\(id.uuidString)", method: "DELETE")
    }

    private func rest(_ path: String, method: String, json: [String: Any]? = nil, body: Data? = nil, prefer: String? = nil) async throws -> Data {
        let token = try await token()
        var req = URLRequest(url: URL(string: Config.supabaseURL.absoluteString + "/rest/v1/" + path)!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let json { req.httpBody = try JSONSerialization.data(withJSONObject: json) } else { req.httpBody = body }
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return data
    }

    // MARK: - Chat and voice

    struct Turn: Encodable { let role: String; let content: String }

    /// Streams the agent's reply; `onText` gets each new piece, `onOrder` each update of an
    /// order the agent placed (shops only). Returns the full reply.
    func chat(agentId: UUID, turns: [Turn], onText: @escaping (String) -> Void,
              onOrder: @escaping (OrderUpdate) -> Void = { _ in }) async throws -> String {
        let req = try await functionRequest("chat", body: ["agent_id": agentId.uuidString, "messages": turns.map { ["role": $0.role, "content": $0.content] }])
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 4000 { break } }
            try check(response, body)
        }
        var full = ""
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw BackendError(message: err) }
            if let t = obj["text"] as? String { full += t; onText(t) }
            if let o = obj["order"], let data = try? JSONSerialization.data(withJSONObject: o),
               let update = try? decoder.decode(OrderUpdate.self, from: data) {
                onOrder(update)
            }
        }
        return full
    }

    /// Wakes the chat function (and its auth key cache) before you speak, to hide cold starts.
    func warmUp() {
        Task {
            guard let req = try? await functionRequest("chat", body: ["warm": true]) else { return }
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    /// Raw PCM16 at 24 kHz in the given ElevenLabs voice.
    func speechStream(text: String, voiceId: String) async throws -> URLSession.AsyncBytes {
        let req = try await functionRequest("tts", body: ["text": text, "voice_id": voiceId])
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw BackendError(message: http.statusCode == 503 ? "no-server-voice" : "Voice error \(http.statusCode)")
        }
        return bytes
    }

    private func functionRequest(_ name: String, body: [String: Any]? = nil) async throws -> URLRequest {
        let token = try await token()
        var req = URLRequest(url: Config.supabaseURL.appendingPathComponent("functions/v1/\(name)"))
        req.httpMethod = body == nil ? "GET" : "POST"
        req.timeoutInterval = 60
        req.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return req
    }

    /// Calls a function and decodes its JSON answer (errors become BackendError).
    private func function<T: Decodable>(_ name: String, body: [String: Any]? = nil, timeout: TimeInterval = 60) async throws -> T {
        var req = try await functionRequest(name, body: body)
        req.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: req)
        try check(response, data)
        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Payments

    /// Turns payments on for one of your public agents and saves its catalog (empty = off).
    func saveCatalog(agentId: UUID, items: [CatalogItem]) async throws -> [CatalogItem] {
        struct Saved: Decodable { let items: [CatalogItem] }
        let body: [String: Any] = [
            "agent_id": agentId.uuidString,
            "items": items.map { i -> [String: Any] in
                var row: [String: Any] = ["name": i.name, "price_usdc": i.priceUsdc, "note": i.note]
                if let id = i.id { row["id"] = id.uuidString }
                return row
            },
        ]
        return try await (function("merchant", body: body, timeout: 90) as Saved).items
    }

    func catalog(agentId: UUID) async throws -> [CatalogItem] {
        let data = try await rest("catalog_items?select=id,name,note,price_usdc&agent_id=eq.\(agentId.uuidString)&active=eq.true&order=position",
                                  method: "GET")
        return try decoder.decode([CatalogItem].self, from: data)
    }

    /// Has your wallet agent buy something. Within your limits it pays straight away;
    /// above them it comes back as `checkpoint` until you approve it with World ID.
    func pay(agentId: UUID, itemId: UUID, qty: Int, approvalId: String? = nil) async throws -> OrderUpdate {
        var body: [String: Any] = ["agent_id": agentId.uuidString, "item_id": itemId.uuidString, "qty": qty]
        if let approvalId { body["approval_id"] = approvalId }
        var req = try await functionRequest("pay", body: body)
        req.timeoutInterval = 90
        let (data, _) = try await URLSession.shared.data(for: req)
        // pay answers with a status even when it refuses (denied, failed).
        if let update = try? decoder.decode(OrderUpdate.self, from: data) { return update }
        throw BackendError(message: "Unexpected answer from your wallet")
    }

    func wallet() async throws -> WalletInfo { try await function("pay") }

    func saveLimits(autoLimit: Double, dailyBudget: Double) async throws {
        struct Ack: Decodable {}
        let _: Ack = try await function("pay/settings", body: ["auto_limit_usdc": autoLimit, "daily_budget_usdc": dailyBudget])
    }

    /// Where to send you to verify with World ID (`verify_shop`) or approve a purchase (`checkpoint`).
    func worldStart(purpose: String, approvalId: String? = nil) async throws -> URL {
        struct Start: Decodable { let url: String }
        var body: [String: Any] = ["purpose": purpose]
        if let approvalId { body["approval_id"] = approvalId }
        let start: Start = try await function("world/start", body: body)
        guard let url = URL(string: start.url) else { throw BackendError(message: "Bad World ID link") }
        return url
    }

    /// Your own World ID verification, if you have one.
    func worldIdentity() async throws -> WorldIdentity? {
        let data = try await rest("world_identities?select=acr,verified_at", method: "GET")
        return try decoder.decode([WorldIdentity].self, from: data).first
    }

    func shopProfile(agentId: UUID) async throws -> ShopProfile? {
        let data = try await rest("rpc/shop_profile", method: "POST", json: ["p_agent": agentId.uuidString])
        return try decoder.decode([ShopProfile].self, from: data).first
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw BackendError(message: "No response") }
        guard (200..<300).contains(http.statusCode) else {
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = (obj?["error"] as? String) ?? (obj?["message"] as? String) ?? (obj?["msg"] as? String)
                ?? (obj?["error_description"] as? String) ?? "Server error \(http.statusCode)"
            throw BackendError(message: msg)
        }
    }
}

/// Agents' voices from the server (ElevenLabs behind the `tts` function).
/// If the server has no voice key it steps aside for a while and Apple's voice takes over.
final class ServerVoice: VoiceEngine, @unchecked Sendable {
    let label = "Agentsphere voice"
    private let lock = NSLock()
    private var disabledUntil = Date.distantPast

    var isAvailable: Bool { Config.isConfigured && lock.withLock { Date() > disabledUntil } }

    func speak(_ text: String, voiceIndex: Int, onChunk: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        let voice = VoicePalette.voices[voiceIndex % VoicePalette.voices.count].id
        do {
            let bytes = try await Backend.shared.speechStream(text: text, voiceId: voice)
            try await PCM16.stream(bytes, sampleRate: 24000, onChunk: onChunk)
        } catch let e as BackendError where e.message == "no-server-voice" {
            lock.withLock { disabledUntil = Date().addingTimeInterval(300) }
            throw BackendError(message: "Server has no voice key")
        }
    }
}
