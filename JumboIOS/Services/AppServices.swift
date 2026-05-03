import Foundation

// MARK: - AppServices
//
// Central service container. View models read their dependencies from
// `AppServices.shared.chatService` and `AppServices.shared.watchPartyService`
// instead of touching concrete singletons (`MockChatService.shared`,
// `MockWatchPartyService.shared`).
//
// Two `AppConfig` flags control which conformer is wired in:
//
//   • `AppConfig.useRemoteChat`     → swaps Mock → Remote chat
//   • `AppConfig.useRemoteParties`  → swaps Mock → Remote parties
//
// Today both flags are `false`, so both properties point at the in-memory
// mocks and behavior is identical to before. The Supabase-backed
// `RemoteChatService` / `RemoteWatchPartyService` are not yet implemented;
// flipping a flag without writing the corresponding conformer will trigger
// a clear runtime crash from this file pointing at the missing piece.
//
// Adding the remote backend later is a four-line change at most:
//   1. Implement `RemoteChatService: ChatServiceProtocol` (Supabase calls).
//   2. Replace the `preconditionFailure` below with `RemoteChatService.shared`.
//   3. Set `AppConfig.useRemoteChat = true`.
//   4. (Same three steps for parties.)
// View models do NOT change — they already speak to the protocol.

@MainActor
final class AppServices {
    static let shared = AppServices()

    let chatService: any ChatServiceProtocol
    let watchPartyService: any WatchPartyServiceProtocol

    private init() {
        self.chatService = Self.makeChatService()
        self.watchPartyService = Self.makeWatchPartyService()
    }

    /// Test/preview seam — let callers compose a custom container with their
    /// own service conformers without touching the shared singleton.
    init(
        chatService: any ChatServiceProtocol,
        watchPartyService: any WatchPartyServiceProtocol
    ) {
        self.chatService = chatService
        self.watchPartyService = watchPartyService
    }

    // MARK: - Conformer selection

    private static func makeChatService() -> any ChatServiceProtocol {
        // Flag-driven routing. `useRemoteChat = false` keeps the app on the
        // in-memory mock by default (safe for local testing of UI and other
        // services); flip the flag in `AppConfig` to send all chat traffic
        // through the real Supabase-backed `RemoteChatService` for
        // controlled backend testing.
        if AppConfig.useRemoteChat {
            return RemoteChatService.shared
        }
        return MockChatService.shared
    }

    // MARK: - Controlled rollout accessor
    //
    // Returns the chat service that the *core chat screens* (game room,
    // team page, trending room) should use during the rollout to the real
    // Supabase backend. Currently always `RemoteChatService` so those
    // surfaces hit the real backend, while the rest of the app — feed,
    // threads, money rooms, anything else that resolves `chatService`
    // through the global accessor — keeps using whatever `makeChatService`
    // picked (the mock under today's flag).
    //
    // Once the rollout is verified end-to-end, every consumer can move to
    // `AppServices.shared.chatService` and this accessor + its three call
    // sites can be deleted in one pass.

    func chatServiceForChatScreens() -> any ChatServiceProtocol {
        return RemoteChatService.shared
    }

    private static func makeWatchPartyService() -> any WatchPartyServiceProtocol {
        if AppConfig.useRemoteParties {
            // Future: return RemoteWatchPartyService.shared
            //
            // RemoteWatchPartyService will be a Supabase-backed conformer of
            // `WatchPartyServiceProtocol`. Until it lands, fail loudly so the
            // flag can't be flipped accidentally without a working implementation.
            preconditionFailure(
                "AppConfig.useRemoteParties is true but RemoteWatchPartyService is not implemented yet. " +
                "Implement it as a WatchPartyServiceProtocol conformer, then return RemoteWatchPartyService.shared here."
            )
        }
        return MockWatchPartyService.shared
    }
}
