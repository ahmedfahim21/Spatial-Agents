import Foundation

/// Supabase project. The publishable key is public by design (row-level security protects data).
/// Never put the secret key here.
enum Config {
    static let supabaseURL = URL(string: "https://fyfccjtcrqsqgtlmtioc.supabase.co")!
    static let supabaseAnonKey = "sb_publishable_5FitKzGghtCPNenleBzMQA_ITzc_sIo"
    static var isConfigured: Bool { !supabaseAnonKey.hasPrefix("YOUR") }
}
