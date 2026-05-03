import Foundation

// MARK: - Supabase configuration
//
// Credentials are read in this order:
//
//   1. `Bundle.main.infoDictionary["SupabaseURL"]` /
//      `Bundle.main.infoDictionary["SupabaseAnonKey"]`
//
//      These keys are populated from build settings supplied by
//      `Supabase.xcconfig` (gitignored — see `.gitignore` and
//      `Supabase.xcconfig.example`). Wiring instructions live at the top of
//      `Supabase.xcconfig`. Once that's wired, this file holds NO secrets.
//
//   2. The hardcoded fallbacks below.
//
//      Until the xcconfig path is wired in Xcode, the app reads from these
//      values so it keeps working. They WILL be deleted once the xcconfig
//      path is live and the secrets have been rotated.
//
// The URL stored here is the project ROOT URL — no path suffix. The
// Supabase Swift SDK appends `/rest/v1/`, `/auth/v1/`, etc. itself.

enum SupabaseConfig {
    // MARK: - Read accessors

    static var projectURL: String {
        bundleString("SupabaseURL") ?? fallbackProjectURL
    }

    static var anonKey: String {
        bundleString("SupabaseAnonKey") ?? fallbackAnonKey
    }

    /// True when both values are present (from either source) and the URL
    /// looks like a Supabase project URL.
    static var isConfigured: Bool {
        let url = projectURL
        let key = anonKey
        return !url.isEmpty
            && !key.isEmpty
            && url.contains("supabase.co")
    }

    // MARK: - Fallbacks (committed; rotate + remove once xcconfig is live)

    private static let fallbackProjectURL = "https://wxpogyatoxijmglihncm.supabase.co"
    private static let fallbackAnonKey = "sb_publishable_JyQtaFn-Mpx1KHEJ9ZWPfA_3Qz7c9lL"

    // MARK: - Helpers

    private static func bundleString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
