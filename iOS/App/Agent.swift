import Foundation
import SwiftUI

/// A personal or public agent (coding agents live on the Mac).
struct Agent: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case personal, `public` }
    enum Anchor: String, Codable { case body, geo }
    enum Visibility: String, Codable { case `private`, `public` }

    var id: UUID
    var name: String
    var emoji: String?
    var color: String?
    /// Body shape (circle, hexagon, squircle, capsule, drop); see `botShape`.
    var shape: String?
    var voiceId: String?
    var greeting: String
    /// Only present for agents you own; public discovery never returns it.
    var context: String?
    var kind: Kind?
    var anchor: Anchor?
    var visibility: Visibility
    var lat: Double?
    var lng: Double?
    var radiusM: Double
    var pricing: String
    var priceUsd: Double?
    var walletAddress: String?
    /// From nearby search.
    var isMine: Bool?
    var distanceM: Double?
    /// The owner verified with World ID (nearby search only).
    var verified: Bool?
    /// The 0G router chat model it thinks with (nil = the server default).
    var model: String?

    var isGeo: Bool { anchor == .geo || (anchor == nil && lat != nil) }
    var isPublic: Bool { visibility == .public }
    var tint: Color { botColor.color }
    var voiceIndex: Int { VoicePalette.index(of: voiceId) }
}

/// Fields sent when creating an agent.
struct NewAgent: Encodable {
    var kind: Agent.Kind
    var anchor: Agent.Anchor
    var visibility: Agent.Visibility
    var name: String
    var emoji: String?
    var color: String?
    var shape: String?
    var voiceId: String?
    var greeting: String
    var context: String
    var lat: Double?
    var lng: Double?
    var radiusM: Double
    var pricing = "free"
    var walletAddress: String?
    /// Nil = the server default.
    var model: String?
}

/// Voices agents can pick from: ElevenLabs premade voices (via the server), with a matching
/// on-device fallback chosen by index.
enum VoicePalette {
    static let voices: [(name: String, id: String)] = [
        ("Sarah", "EXAVITQu4vr4xnSDxMaL"),
        ("George", "JBFqnCBsd6RMkjVDRZzb"),
        ("Lily", "pFZP5JQG7iQjIQuC4Bku"),
        ("Brian", "nPczCjzI2devNBz1zQrb"),
        ("Aria", "9BWtsMINqrJLrRacOk9x"),
        ("Daniel", "onwK4e9ZLuTAKqWW03F9"),
        ("Matilda", "XrExE9yKIg1WjnnlVkGX"),
        ("Charlie", "IKne3meq5aSn9XLyUdCD"),
    ]
    static func index(of id: String?) -> Int { voices.firstIndex { $0.id == id } ?? 0 }
}

extension Color {
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
