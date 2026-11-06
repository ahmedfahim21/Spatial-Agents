import Foundation

/// Supabase project. The anon key is public by design (row-level security protects data).
enum Config {
    static let supabaseURL = URL(string: "https://YOUR-PROJECT.supabase.co")!
    static let supabaseAnonKey = "YOUR-ANON-KEY"
    static var isConfigured: Bool { !supabaseAnonKey.hasPrefix("YOUR") }
}
