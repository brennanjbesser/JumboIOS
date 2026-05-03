import Foundation

/// Build- and environment-level configuration.
///
/// Flip `useMockProvider` to `false` once the JUMBO backend is deployed and
/// reachable at `backendBaseURL`. Polling intervals can be tuned per release.
enum AppConfig {
    /// When `true`, `LiveScoreService` uses `MockLiveScoreProvider` (no network).
    /// When `false`, it uses `RemoteLiveScoreProvider` against `backendBaseURL`.
    static let useMockProvider: Bool = true

    /// Base URL of the JUMBO backend that proxies/normalizes ESPN (or any
    /// other upstream score provider). Never call ESPN directly from iOS.
    static let backendBaseURL: URL = URL(string: "http://localhost:3000")!

    /// Path of the live games endpoint on the JUMBO backend.
    /// Returns `LiveGameAPIResponse` shape (provider-agnostic).
    static let liveGamesEndpoint: String = "/api/live-games"

    /// Default polling interval (seconds) for the Live Games screen.
    static let pollingIntervalDefault: TimeInterval = 30

    /// Boosted polling interval (seconds) used while the user is actively
    /// inside a game chat room.
    static let pollingIntervalActive: TimeInterval = 15

    /// Network timeout for a single live-games request.
    static let requestTimeout: TimeInterval = 10

    // MARK: - Backend cutover flags
    //
    // These gate the swap from in-memory mock services to the future
    // Supabase-backed conformers. They are read by `AppServices` at app
    // launch and decide which `ChatServiceProtocol` / `WatchPartyServiceProtocol`
    // implementation gets wired into the container.
    //
    // Flip to `true` only AFTER the corresponding `RemoteChatService` /
    // `RemoteWatchPartyService` is implemented and the Supabase product is
    // linked into the JumboIOS target. Until then, leave both `false`.

    /// When `true`, `AppServices` wires `chatService` to `RemoteChatService.shared`
    /// (Supabase-backed). When `false`, it uses `MockChatService.shared`.
    static let useRemoteChat: Bool = false

    /// When `true`, `AppServices` wires `watchPartyService` to
    /// `RemoteWatchPartyService.shared` (Supabase-backed). When `false`, it
    /// uses `MockWatchPartyService.shared`.
    static let useRemoteParties: Bool = false
}
