import SwiftUI
import Combine
import OSLog

private let logger = Logger(subsystem: "com.jumbo", category: "chat")

// NOTE: Posts in this view model come from `MockChatService` while we wait
// for the real backend. We deliberately do NOT seed any fake user posts or
// simulated activity here — the empty room shows starter prompts (see
// `ChatStarterPrompts`) until the first real post arrives. Real chat will
// flow through this view model once the chat backend is wired in.

@MainActor
class GameRoomViewModel: ObservableObject {
    @Published private(set) var game: LiveGame
    // Resolved via the controlled-rollout accessor so this screen uses
    // RemoteChatService while the rest of the app stays on the mock. When
    // the rollout finishes, swap back to `AppServices.shared.chatService`.
    let service: any ChatServiceProtocol = AppServices.shared.chatServiceForChatScreens()

    @Published var posts: [Post] = []
    @Published var sortOption: FeedSortOption = .new {
        didSet {
            Task { await loadPosts() }
        }
    }
    @Published var isLoading = false
    @Published var newPostsCount = 0

    private var cancellables = Set<AnyCancellable>()
    private var pendingPosts: [Post] = []

    /// Posts whose vote/removeVote round-trip is currently in flight.
    /// Rapid repeat taps on the same post check this set and bail —
    /// prevents racing two upserts and the resulting count flicker
    /// when the second-tap optimistic mutation lands on top of the
    /// first one's pending result. @MainActor-isolated so plain Set
    /// operations are thread-safe.
    private var inFlightVoteIds: Set<UUID> = []

    /// Anti-spam: rejects vote taps that arrive within 300ms of the
    /// previous one. Complements `inFlightVoteIds` (which gates by
    /// per-post pending state) by also throttling cross-post tap
    /// bursts (e.g. user mashing votes down a long feed).
    private var lastVoteTime: Date = .distantPast

    /// Transient error string for the top-anchored toast banner. Set
    /// by `showTransientError(_:)` on action failure; auto-cleared
    /// after ~2s by the same helper. `@Published` so the View overlay
    /// reacts immediately.
    @Published var transientError: String?
    private var transientErrorClearTask: Task<Void, Never>?

    private func showTransientError(_ message: String) {
        transientError = message
        transientErrorClearTask?.cancel()
        transientErrorClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientError = nil
        }
    }

    init(game: LiveGame) {
        self.game = game
        // Initial room is always the legacy team-pair model so the
        // chat surface is never empty while the canonical resolver
        // is in flight. If a canonical game_rooms.room_id exists for
        // this game, the async upgrade below swaps the room and
        // re-subscribes. If it doesn't (mock provider, deleted seed,
        // network blip), this team-pair room remains the chat scope
        // — exactly today's behavior.
        self.room = .game(homeTeamId: game.homeTeam.id, awayTeamId: game.awayTeam.id)

        service.notificationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleNotification(notification)
            }
            .store(in: &cancellables)

        // Track live score updates for this specific game.
        LiveScoreService.shared.$liveGames
            .receive(on: DispatchQueue.main)
            .sink { [weak self] games in
                guard let self else { return }
                if let updated = games.first(where: { $0.id == self.game.id }) {
                    self.game = updated
                }
            }
            .store(in: &cancellables)

        // Subscribe to realtime post inserts for THIS game's room. The
        // server filter is `room_id=eq.<uuid>` — a single, uniform filter
        // that completely isolates this game chat from team chats.
        let subscriptionService = service
        let scopeRoom = room
        let homeShortName = game.homeTeam.shortName
        let awayShortName = game.awayTeam.shortName
        logger.debug("🎮 GameRoomViewModel.init: matchup \(awayShortName) @ \(homeShortName) → subscribing room=\(scopeRoom.roomType):\(scopeRoom.roomId.uuidString) (team-pair fallback)")
        Task { @MainActor in
            await subscriptionService.subscribeToPosts(room: scopeRoom)
        }

        // Try to upgrade to the canonical room (one row per real
        // scheduled game in `public.game_rooms`). Fire-and-forget —
        // if it succeeds and returns a different roomId, we swap;
        // if it returns nil, throws, or matches the current
        // fallback, we stay on team-pair.
        Task { @MainActor [weak self] in
            await self?.upgradeToCanonicalRoomIfAvailable()
        }
    }

    /// Current chat-room identity. Starts as the legacy team-pair
    /// `.game(home, away)` and is swapped to `.canonicalGame(roomId:)`
    /// in `upgradeToCanonicalRoomIfAvailable()` when a row exists in
    /// `public.game_rooms` for this game. `var` (not `let`) because
    /// the room can be upgraded mid-flight; deinit captures the
    /// current value at tear-down time, which is correct for the
    /// resubscription contract.
    var room: ChatRoom

    /// Asks SportsGameService for the canonical `game_rooms` row
    /// matching `game.id`. If one exists with a `room_id` different
    /// from the current team-pair fallback, switches subscriptions
    /// and reloads posts. Safe no-op when no row exists, fetch fails,
    /// or the canonical room id happens to equal the existing one.
    private func upgradeToCanonicalRoomIfAvailable() async {
        do {
            guard let gameRoom = try await SportsGameService.shared.fetchGameRoom(forGameId: game.id) else {
                logger.info("ℹ️ GameRoomViewModel: no canonical game_rooms row for game \(self.game.id) — staying on team-pair fallback room \(self.room.roomId)")
                return
            }
            let canonicalRoom: ChatRoom = .canonicalGame(roomId: gameRoom.roomId)
            // Defensive: if the canonical room id somehow matches the
            // team-pair-derived id (shouldn't happen — different
            // hashes), don't churn subscriptions.
            guard canonicalRoom.roomId != room.roomId else {
                logger.debug("GameRoomViewModel: canonical room id matches team-pair — no upgrade needed")
                return
            }
            logger.info("✅ GameRoomViewModel: upgrading game room \(self.room.roomId) (team-pair) → \(canonicalRoom.roomId) (canonical game_rooms.room_id)")
            // Tear down the team-pair subscription before we install
            // the canonical one to avoid double-fanout.
            let oldRoom = room
            await service.unsubscribeFromPostScope(room: oldRoom)
            self.room = canonicalRoom
            await service.subscribeToPosts(room: canonicalRoom)
            // Reload posts because the room id changed — the previous
            // load was for a different (and likely empty) team-pair
            // scope.
            await loadPosts()
        } catch {
            logger.error("❌ GameRoomViewModel: canonical room fetch threw — staying on team-pair fallback: \(error)")
        }
    }

    deinit {
        let subscriptionService = service
        let scopeRoom = room
        Task { @MainActor in
            await subscriptionService.unsubscribeFromPostScope(room: scopeRoom)
        }
    }

    // MARK: - Load Posts

    func loadPosts() async {
        isLoading = true
        do {
            // Single room-scoped fetch — no more home/away merge dance.
            posts = try await service.fetchPostsForRoom(room, sortBy: sortOption)
        } catch {
            logger.error("Error loading game room posts: \(error)")
        }
        isLoading = false
    }

    func refresh() async {
        newPostsCount = 0
        pendingPosts = []
        await loadPosts()
    }

    // MARK: - Create Post

    /// Returns `true` on accepted send, `false` on empty-content bail
    /// or network failure. Mirrors createReply's contract.
    @discardableResult
    func createPost(content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            // Posts go to the GAME room, not either team's chat. Server
            // sets `room_id` from `room.roomId`; metadata `team_id` is nil.
            _ = try await service.createPost(content: trimmed, room: room, parentId: nil)
            return true
        } catch {
            logger.error("Error creating post: \(error)")
            showTransientError("Couldn't send. Try again.")
            return false
        }
    }

    // MARK: - Voting

    func vote(on post: Post, type: VoteType) async {
        if Date().timeIntervalSince(lastVoteTime) < 0.3 {
            return
        }
        lastVoteTime = Date()

        guard !inFlightVoteIds.contains(post.id) else { return }
        inFlightVoteIds.insert(post.id)
        defer { inFlightVoteIds.remove(post.id) }

        do {
            let currentVote = service.getUserVote(for: post.id)
            if currentVote == type {
                _ = try await service.removeVote(from: post.id)
            } else {
                _ = try await service.vote(on: post.id, type: type)
            }
            if let index = posts.firstIndex(where: { $0.id == post.id }),
               let updatedPost = service.getPost(by: post.id) {
                posts[index] = updatedPost
                // Originating-device re-sort: the realtime echo of our
                // own write hits handleVoteAction's same-user skip and
                // never emits .postUpdated, so handleNotification doesn't
                // run on this device. Re-sort here so Hot/Top reposition
                // immediately instead of waiting for the 1.5s sanity check.
                posts = posts.sortedByFeed(sortOption)
            }
        } catch {
            logger.error("Error voting: \(error)")
            showTransientError("Vote failed. Try again.")
        }
    }

    func getUserVote(for postId: UUID) -> VoteType? {
        service.getUserVote(for: postId)
    }

    // MARK: - Moderation

    func reportPost(_ post: Post, reason: ReportReason, additionalInfo: String?) async {
        do {
            try await service.reportPost(post.id, reason: reason, additionalInfo: additionalInfo)
        } catch {
            logger.error("Error reporting: \(error)")
        }
    }

    func blockUser(_ userId: UUID) async {
        do {
            try await service.blockUser(userId)
            posts.removeAll { $0.authorId == userId }
        } catch {
            logger.error("Error blocking: \(error)")
        }
    }

    func deletePost(_ post: Post) async {
        do {
            try await service.deletePost(post.id)
            posts.removeAll { $0.id == post.id }
        } catch {
            logger.error("Error deleting: \(error)")
        }
    }

    // MARK: - New Posts

    func showNewPosts() {
        posts.insert(contentsOf: pendingPosts, at: 0)
        pendingPosts = []
        newPostsCount = 0
    }

    // MARK: - Notifications

    /// Realtime delta handler. The Supabase RPC `get_room_posts` is the
    /// canonical source of feed order — initial fetches come back already
    /// sorted. After a delta arrives (new post, vote count change), we
    /// re-apply the same sort locally via `sortedByFeed` so the position
    /// stays consistent with what a fresh fetch would return.
    private func handleNotification(_ notification: ChatNotification) {
        switch notification {
        case .newPost(let post):
            guard post.parentId == nil else { return }
            // Filter by room membership — keeps team posts out of the
            // game chat and vice versa.
            guard post.belongs(to: room) else { return }
            if !posts.contains(where: { $0.id == post.id }) {
                // Wrapped in withAnimation so the per-card
                // `.transition(.opacity + .move(.bottom))` fires for
                // the new arrival — fade + slight upward slide makes
                // the post feel like it's "arriving live in the
                // stadium". loadPosts assigns the array without
                // wrapping, so cold-start cards skip this transition.
                withAnimation(AnimationConfig.snappy) {
                    posts.append(post)
                    posts = posts.sortedByFeed(sortOption)
                }
            }

        case .postUpdated(let post):
            // No withAnimation — vote / reply-count updates re-sort in
            // place silently per spec ("do not animate vote updates or
            // sort changes"). The card's `.transition` won't fire for
            // updates anyway because the item isn't being inserted.
            if let index = posts.firstIndex(where: { $0.id == post.id }) {
                posts[index] = post
                posts = posts.sortedByFeed(sortOption)
            }

        case .postDeleted(let postId):
            posts.removeAll { $0.id == postId }

        case .scoreUpdate:
            break
        }
    }
}
