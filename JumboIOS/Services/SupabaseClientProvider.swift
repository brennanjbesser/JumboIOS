import Foundation
import Supabase

// MARK: - SupabaseClientProvider
//
// Owns the single `SupabaseClient` instance for the app. Exposed via
// `SupabaseClientProvider.shared.client` so that future remote services
// (`RemoteChatService`, `RemoteWatchPartyService`) share one client and one
// connection pool, rather than each spinning up their own.
//
// This file does NOT perform any data fetching, auth, or realtime work —
// it just constructs the client from `SupabaseConfig`. Consumers (which
// don't exist yet) will use `client.from("...")`, `client.auth`, etc.
//
// `client` is `nil` when `SupabaseConfig.isConfigured` returns false (no
// URL / key found in either Bundle or fallbacks). Callers must guard.

@MainActor
final class SupabaseClientProvider {
    static let shared = SupabaseClientProvider()

    let client: SupabaseClient?

    private init() {
        guard SupabaseConfig.isConfigured,
              let url = URL(string: SupabaseConfig.projectURL) else {
            print("⚠️ SupabaseClientProvider: not configured — client unavailable. " +
                  "Check SupabaseConfig and Supabase.xcconfig.")
            self.client = nil
            return
        }

        self.client = SupabaseClient(
            supabaseURL: url,
            supabaseKey: SupabaseConfig.anonKey
        )

        print("✅ SupabaseClientProvider: client initialized for \(url.absoluteString)")
    }
}
