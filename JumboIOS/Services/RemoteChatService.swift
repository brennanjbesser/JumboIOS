import Foundation
import Combine
import OSLog
import Supabase

// Subsystem-wide logger for the chat backend. Success/info-level logs
// use `.debug` (stripped from release builds by default unified-logging
// behavior); failures use `.error`. Privacy: relying on the default
// `.private` redaction for interpolated values in Console.app — visible
// in Xcode debugger console during development.
private let logger = Logger(subsystem: "com.jumbo", category: "chat")

// MARK: - RemoteChatService
//
// Supabase-backed conformer of `ChatServiceProtocol`. Backed by
// `SupabaseClientProvider.shared.client`.
//
// VOTE-COUNT SOURCE OF TRUTH
// --------------------------
// The `votes` table (rows where `is_active = true`) is the single source
// of truth for upvote / downvote counts. iOS NEVER reads
// `posts.upvotes` / `posts.downvotes` for UI correctness — those columns
// are server-side cache / analytics only, maintained by the
// `recalculate_post_vote_counts` trigger for the benefit of admin SQL,
// future REST consumers, and BI exports.
//
// Why: the trigger has historically drifted (counts at 0 even when vote
// rows exist), so iOS computes counts directly from the `votes` table:
//
//   • cold start (`fetchPostsForRoom`) → SELECT votes WHERE post_id IN (…)
//                                          AND is_active = true
//                                        aggregate up/down per post,
//                                        overlay onto returned Posts.
//
//   • realtime updates (`handleVoteAction`) → compute delta from the
//                                              event's (is_active,
//                                              vote_type) transition,
//                                              apply to cached Post.
//
//   • sanity check (`refetchPostCounts`)  → re-aggregate from votes
//                                            table ~1.5s after a delta,
//                                            silently correct any drift
//                                            (no emit if it matches).
//
// Soft-delete model: `removeVote(from:)` UPDATEs `is_active=false` on
// the existing row instead of DELETEing it. Postgres realtime DELETE
// events deliver only the primary key in oldRecord (SDK behavior even
// with REPLICA IDENTITY FULL), so other devices can't act on a hard
// delete; an UPDATE event delivers full old + new rows so the delta
// math works end-to-end.
//
// `team_id` is a UUID column on the Supabase `posts` table — same UUID
// the iOS app uses (`SportsTeam.id`). No string-id conversion or
// `TeamDatabase` lookup happens here; the UUID is round-tripped
// untouched.
//
// Schema (matches the file-private wire models below):
//
//   posts(
//     id          uuid primary key default gen_random_uuid(),
//     user_id     uuid not null references users(id),
//     content     text not null,
//     room_id     uuid not null,         -- chat-room scope
//     room_type   text not null,         -- "team" / "game" / "trending"
//     team_id     uuid,                  -- legacy, denormalized
//     parent_id   uuid,
//     upvotes     int default 0,         -- cache only; iOS ignores
//     downvotes   int default 0,         -- cache only; iOS ignores
//     reply_count int default 0,
//     report_count int default 0,
//     is_hidden   bool default false,
//     created_at  timestamptz default now(),
//     updated_at  timestamptz default now()
//   )
//
//   votes(
//     id         uuid primary key default gen_random_uuid(),
//     user_id    uuid not null references users(id),
//     post_id    uuid not null references posts(id),
//     room_id    uuid not null,
//     vote_type  text not null,          -- "up" / "down"
//     is_active  boolean not null default true,  -- soft-delete flag
//     created_at timestamptz default now(),
//     UNIQUE (user_id, post_id)
//   )
//
// To wire this into the app, set `AppConfig.useRemoteChat = true` (this
// also requires returning `RemoteChatService.shared` from
// `AppServices.makeChatService`).

@MainActor
final class RemoteChatService: ObservableObject, ChatServiceProtocol {
    static let shared = RemoteChatService()

    // MARK: - Protocol-required state

    /// Local identity. We don't have Supabase Auth wired yet, so we mirror
    /// the device-local user id from UserPreferences — same identity the
    /// mock service uses, so cards correctly identify "my own" posts.
    @Published private(set) var currentUser: AnonymousUser

    /// Local cache of posts seen this session. Populated by `fetchPostsForTeam`
    /// and `createPost`. No de-duplication across teams; this is intentionally
    /// minimal until a real cache layer lands.
    @Published private(set) var posts: [Post] = []

    /// Local cache of THIS user's votes, keyed by post id. Populated when
    /// posts are fetched (via a paired query against the votes table) and
    /// kept current as `vote` / `removeVote` succeed. Backs the synchronous
    /// `getUserVote(for:)` lookup that the protocol requires.
    @Published private(set) var userVotes: [UUID: VoteType] = [:]

    // MARK: - Combine streams (protocol-required, currently inert)

    private let postsSubject = PassthroughSubject<[Post], Never>()
    private let notificationSubject = PassthroughSubject<ChatNotification, Never>()

    var postsPublisher: AnyPublisher<[Post], Never> {
        postsSubject.eraseToAnyPublisher()
    }

    var notificationPublisher: AnyPublisher<ChatNotification, Never> {
        notificationSubject.eraseToAnyPublisher()
    }

    // MARK: - Supabase client

    private var client: SupabaseClient? {
        SupabaseClientProvider.shared.client
    }

    /// Set to `true` after the first successful `ensureCurrentUserExists()`
    /// in this session so subsequent posts don't redundantly upsert the
    /// user row on every insert. Resets on app restart (singleton lifetime).
    private var hasEnsuredUser = false

    // MARK: - Realtime subscription registry
    //
    // Multiple scoped subscriptions can be active concurrently. A scope is
    // identified by its `teamIds` — the same set of ids (in any order)
    // addresses the same subscription. This lets a deep-stacked nav (e.g.
    // GameRoom for [A,B] underneath TeamPage for [B] underneath …) keep
    // every chat screen receiving realtime independently.
    //
    // Idempotency:
    //   • subscribeToPosts(teamIds:) for an existing scope is a no-op.
    //   • unsubscribeFromPostScope(teamIds:) only tears down that scope
    //     and leaves the rest untouched.

    private struct PostSubscription {
        let channel: RealtimeChannelV2
        let listenerTask: Task<Void, Never>
        /// Observes `channel.statusChange` and triggers `attemptReconnect`
        /// on `.unsubscribed` (network drop / gateway timeout). Cancelled
        /// in `unsubscribeFromPostScope` so intentional teardowns don't
        /// trip the reconnect path.
        let watcherTask: Task<Void, Never>
        let roomId: UUID
    }

    /// Keyed by `roomId.uuidString`. Same room → same key, idempotent.
    private var postSubscriptions: [String: PostSubscription] = [:]

    /// Per-room votes subscription. Opens alongside `postSubscriptions`
    /// inside `subscribeToPosts(room:)` and tears down alongside in
    /// `unsubscribeFromPostScope(room:)`. The `votes` table has no
    /// `room_id` column, so events are received unfiltered server-side
    /// and gated client-side against the local `posts` cache (a vote on
    /// a post we don't have locally means the event isn't for us).
    private struct VoteSubscription {
        let channel: RealtimeChannelV2
        let listenerTask: Task<Void, Never>
        /// Same role as `PostSubscription.watcherTask` — see comment there.
        let watcherTask: Task<Void, Never>
        let roomId: UUID
    }

    private var voteSubscriptions: [String: VoteSubscription] = [:]

    /// Per-room reentrancy guard so multiple status-watchers (posts +
    /// votes) firing `.unsubscribed` in the same window only trigger
    /// one reconnect cycle for that room.
    private var reconnectsInFlight: Set<UUID> = []

    // MARK: - User profile realtime
    //
    // Single app-wide channel listening to UPDATE events on
    // public.users. When a user edits their username / avatar /
    // color, the row's UPDATE event fans out to every device, and
    // this listener:
    //
    //   1. Refreshes `authorProfiles[id]` with the new values.
    //   2. Walks `posts` and updates author fields on every cached
    //      Post for that authorId, then emits `.postUpdated(post)`
    //      for each so room/thread VMs re-render live.
    //   3. Republishes via `userProfileUpdatesPublisher` so
    //      NotificationsViewModel can refresh its own
    //      `userProfiles` cache (and the SwiftUI rows that read
    //      from it).
    //
    // Single channel, started by `startUserProfilesSubscription()`
    // from MainTabView's `.task` and re-armed on `scenePhase ==
    // .active`. The flag below makes both calls idempotent.

    private var userProfilesChannel: RealtimeChannelV2?
    private var userProfilesListenerTask: Task<Void, Never>?
    /// Status watcher — observes `channel.statusChange` and triggers
    /// `attemptUserProfilesReconnect` whenever the channel drops to
    /// `.unsubscribed` (network glitch / gateway timeout / server
    /// restart). Mirrors the per-room watcher pattern used by post +
    /// vote subscriptions.
    private var userProfilesWatcherTask: Task<Void, Never>?
    private var userProfilesSubscribed: Bool = false
    /// Reentrancy guard so multiple drop signals (e.g., scenePhase
    /// .active arriving in the same window as a watcher-triggered
    /// reconnect) collapse into one teardown+resubscribe cycle.
    private var userProfilesReconnectInFlight: Bool = false

    private let userProfileUpdatesSubject = PassthroughSubject<AppUserProfile, Never>()
    /// Fires once per UPDATE event on `public.users`. Subscribers
    /// (e.g., `NotificationsViewModel`) refresh their per-screen
    /// caches so visible rows re-render with the new identity.
    var userProfileUpdatesPublisher: AnyPublisher<AppUserProfile, Never> {
        userProfileUpdatesSubject.eraseToAnyPublisher()
    }

    // MARK: - Author profile cache
    //
    // Resolved profiles for post authors, keyed by user_id. Populated on
    // every fetch (batch SELECT against the `users` table) and on every
    // realtime insert (single SELECT for the new post's author). Cards
    // read decorated profile fields off `Post`, so the UI doesn't need to
    // touch this cache directly.
    //
    // Cleared on app restart (singleton lifetime). A user changing their
    // username mid-session won't propagate until the next post fetch from
    // a device that hasn't already cached them.

    private var authorProfiles: [UUID: AuthorProfile] = [:]

    /// Decoder for realtime payloads. Not the shared `JSONDecoder.supabaseDecoder`
    /// because that one applies `convertFromSnakeCase`, which conflicts
    /// with our explicit snake_case `CodingKeys` on `PostRow`.
    private static let realtimeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = parseSupabaseTimestamp(dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date string \(dateString)"
            )
        }
        return decoder
    }()

    /// Parse Supabase timestamp strings encountered in realtime payloads
    /// AND in normal REST responses. Two flavors show up:
    ///
    ///   • REST `select` responses serialize `timestamptz` columns with a
    ///     `Z` (or `+00:00`) suffix and millisecond precision —
    ///     `ISO8601DateFormatter` handles those with `.withInternetDateTime`
    ///     and `.withFractionalSeconds`.
    ///
    ///   • Realtime postgres-changes payloads serialize timestamps WITHOUT
    ///     a timezone suffix, with up-to-microsecond precision
    ///     ("2026-05-01T15:41:11.947509"). `ISO8601DateFormatter` rejects
    ///     these on two counts: it requires a zone designator, and its
    ///     fractional-seconds support is millisecond-only. We fall through
    ///     to a `DateFormatter` chain that explicitly handles the no-zone
    ///     variants and treats them as UTC (which matches how Supabase
    ///     stores timestamps internally).
    ///
    /// Returns `nil` only if every strategy fails. Caller throws.
    private static func parseSupabaseTimestamp(_ string: String) -> Date? {
        // 1. ISO8601 with timezone + fractional seconds (e.g. "...947Z")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }

        // 2. ISO8601 with timezone, no fractional seconds (e.g. "...11Z")
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }

        // 3. No-timezone variants. Assume UTC — Supabase stores timestamps
        //    in UTC and emits them without a zone suffix on realtime payloads
        //    when the column type is `timestamp` (or in some `timestamptz`
        //    edge cases). Try fractional-second precisions from highest to
        //    lowest so the longest match wins.
        let utcFormatter = DateFormatter()
        utcFormatter.locale = Locale(identifier: "en_US_POSIX")
        utcFormatter.timeZone = TimeZone(secondsFromGMT: 0)

        let noZoneFormats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", // microseconds  (".947509")
            "yyyy-MM-dd'T'HH:mm:ss.SSSSS",  // 5 fractional
            "yyyy-MM-dd'T'HH:mm:ss.SSSS",   // 4 fractional
            "yyyy-MM-dd'T'HH:mm:ss.SSS",    // milliseconds
            "yyyy-MM-dd'T'HH:mm:ss.SS",     // 2 fractional
            "yyyy-MM-dd'T'HH:mm:ss.S",      // 1 fractional
            "yyyy-MM-dd'T'HH:mm:ss"         // none
        ]
        for format in noZoneFormats {
            utcFormatter.dateFormat = format
            if let date = utcFormatter.date(from: string) { return date }
        }

        return nil
    }

    /// Cancellables for the long-lived UserPreferences subscription
    /// (profile-edit → server upsert). Singleton lifetime.
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        self.currentUser = AnonymousUser(
            id: UserPreferences.shared.userId,
            isAdmin: false
        )

        // Profile-edit propagation. When the user edits username /
        // avatarEmoji / avatarColorHex in any UI surface, push the
        // new values to public.users so other devices see the
        // updated identity on their next refresh. Debounced 1s so
        // a typed-out username doesn't generate a flurry of upserts
        // mid-typing — the final value lands once typing settles.
        UserPreferences.shared.profileChangedPublisher
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                Task { [weak self] in
                    await self?.pushCurrentUserProfile()
                }
            }
            .store(in: &cancellables)
    }

    /// Re-upsert the current user's row in public.users with the
    /// latest UserPreferences values, then update the local
    /// authorProfiles cache so this device's own posts/replies
    /// reflect the change immediately on the next render. Empty
    /// fields are backfilled to deterministic values (same logic
    /// as ensureCurrentUserExists) to satisfy the
    /// no-blank-username invariant.
    ///
    /// Idempotent and safe to call repeatedly (one server round-
    /// trip per call). Failures are logged and swallowed — the
    /// local prefs are already saved; the next successful push
    /// (e.g., after network recovers, or via the next profile
    /// edit) will reconcile.
    func pushCurrentUserProfile() async {
        guard let client else {
            logger.error("❌ RemoteChatService.pushCurrentUserProfile: Supabase client unavailable")
            return
        }

        let prefs = UserPreferences.shared
        var resolvedUsername = prefs.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedUsername.isEmpty {
            resolvedUsername = Post.deterministicDisplayName(for: currentUser.id)
        }
        var resolvedEmoji = prefs.avatarEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedEmoji.isEmpty {
            resolvedEmoji = Post.deterministicAvatarEmoji(for: currentUser.id)
        }
        var resolvedColorHex = prefs.avatarColorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedColorHex.isEmpty {
            resolvedColorHex = Post.deterministicAvatarColorHex(for: currentUser.id)
        }

        let payload = UserUpsert(
            id: currentUser.id,
            username: resolvedUsername,
            avatarEmoji: resolvedEmoji,
            avatarColor: resolvedColorHex
        )

        logger.debug("🔵 RemoteChatService.pushCurrentUserProfile: pushing username='\(resolvedUsername)' emoji='\(resolvedEmoji)' color='\(resolvedColorHex)'")

        do {
            try await client
                .from("users")
                .upsert(payload, onConflict: "id")
                .execute()

            // Update local cache so own-device renders pick up the
            // new identity without waiting for the next room/notif
            // refresh round-trip.
            authorProfiles[currentUser.id] = AuthorProfile(
                id: currentUser.id,
                username: resolvedUsername,
                avatarEmoji: resolvedEmoji,
                avatarColorHex: resolvedColorHex
            )
            logger.debug("✅ RemoteChatService.pushCurrentUserProfile: pushed and cache updated")
        } catch {
            logger.error("⚠️ RemoteChatService.pushCurrentUserProfile FAILED (non-fatal — local prefs saved, next push will retry): \(error)")
        }
    }

    // MARK: - createPost (REAL)

    func createPost(content: String, teamId: UUID, parentId: UUID?) async throws -> Post {
        // Legacy entry point — treat as a team-room post.
        try await createPost(content: content, room: .team(teamId), parentId: parentId)
    }

    func createPost(content: String, room: ChatRoom, parentId: UUID?) async throws -> Post {
        guard let client else {
            logger.error("❌ RemoteChatService.createPost: Supabase client unavailable (check SupabaseConfig)")
            throw RemoteChatError.notConfigured
        }

        // Local validation matches the mock so behavior is consistent across
        // the swap. Server-side constraints will catch the same things, but
        // failing fast saves a round-trip.
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            throw RemoteChatError.invalidContent("Post must be at least 2 characters")
        }
        guard trimmed.count <= 280 else {
            throw RemoteChatError.invalidContent("Post must be 280 characters or less")
        }

        // posts.user_id has a FK to users.id — the row must exist before
        // we insert. ensureCurrentUserExists upserts the device user once
        // per session.
        try await ensureCurrentUserExists()

        let dto = PostInsert(
            userId: currentUser.id,
            content: trimmed,
            roomId: room.roomId,
            roomType: room.roomType,
            teamId: room.metadataTeamId,
            parentId: parentId
        )

        logger.debug("🔵 RemoteChatService.createPost: inserting post by \(self.currentUser.id.uuidString) for room=\(room.roomType):\(room.roomId.uuidString) (content length: \(trimmed.count))")

        do {
            let inserted: [PostRow] = try await client
                .from("posts")
                .insert(dto)
                .select()
                .execute()
                .value

            guard let row = inserted.first else {
                logger.error("❌ RemoteChatService.createPost: insert succeeded but returned no row")
                throw RemoteChatError.postCreationFailed
            }

            let raw = row.toPost()
            // Decorate with the current user's profile (seeded by
            // ensureCurrentUserExists into authorProfiles). Without
            // this, the originating device emits an undecorated post
            // and the View falls back to the anonymous identity, while
            // cross-device viewers (whose handlePostInserted decorates)
            // see the real identity — visible mismatch.
            let post = decorate(raw)
            assertDecorated(post, source: "createPost")
            logger.debug("✅ RemoteChatService.createPost: post \(post.id.uuidString) inserted")

            // Single ingest path: inserts into the cache, emits .newPost,
            // and (for replies) bumps parent.replyCount + emits
            // .postUpdated. The realtime echo of this same insert will
            // hit ingestPost again but the dedupe check makes it a no-op,
            // preventing double-counting on the originating device.
            ingestPost(post)

            return post
        } catch let error as RemoteChatError {
            throw error
        } catch {
            logger.error("❌ RemoteChatService.createPost: post insert FAILED")
            logger.debug("    error: \(error)")
            logger.debug("    localized: \(error.localizedDescription)")
            throw RemoteChatError.networkError(error)
        }
    }

    /// Reply creation. Constructs a PostInsert directly from the parent's
    /// stored room identity (room_id / room_type / team_id) so the reply
    /// inherits scope without us needing to reconstruct a `ChatRoom`
    /// enum (which is impossible for game rooms because the enum carries
    /// homeTeamId/awayTeamId that aren't on the Post row).
    func createReply(content: String, parent: Post) async throws -> Post {
        guard let client else {
            logger.error("❌ RemoteChatService.createReply: Supabase client unavailable")
            throw RemoteChatError.notConfigured
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            throw RemoteChatError.invalidContent("Reply must be at least 2 characters")
        }
        guard trimmed.count <= 280 else {
            throw RemoteChatError.invalidContent("Reply must be 280 characters or less")
        }

        try await ensureCurrentUserExists()

        let dto = PostInsert(
            userId: currentUser.id,
            content: trimmed,
            roomId: parent.roomId,
            roomType: parent.roomType,
            teamId: parent.teamId,
            parentId: parent.id
        )

        logger.debug("🔵 RemoteChatService.createReply: inserting reply by \(self.currentUser.id.uuidString) under parent \(parent.id.uuidString) in room=\(parent.roomType):\(parent.roomId.uuidString)")

        do {
            let inserted: [PostRow] = try await client
                .from("posts")
                .insert(dto)
                .select()
                .execute()
                .value

            guard let row = inserted.first else {
                logger.error("❌ RemoteChatService.createReply: insert succeeded but returned no row")
                throw RemoteChatError.postCreationFailed
            }

            let raw = row.toPost()
            // Decorate with the current user's profile (see createPost
            // for the rationale). Originating device must emit a
            // decorated reply so its own thread display matches what
            // every other device sees via the realtime decorate path.
            let reply = decorate(raw)
            assertDecorated(reply, source: "createReply")
            logger.debug("✅ RemoteChatService.createReply: reply \(reply.id.uuidString) inserted")

            // Single ingest path — same as createPost. Inserts into
            // cache, emits .newPost, bumps parent.replyCount, emits
            // .postUpdated. The realtime echo will hit ingestPost
            // again but the dedupe makes it a no-op.
            ingestPost(reply)

            // Best-effort reply notification for the parent post's
            // author. Detached so the network call never delays the
            // reply's success — the reply is already in cache and
            // emitted to subscribers via `ingestPost` above. The
            // AppNotificationService self-skips when source == user
            // (replying to your own post), so we don't need an
            // explicit check here. Failures (RLS, FK, network) are
            // logged and swallowed; the reply itself stays posted.
            let recipientUserId = parent.authorId
            let sourceUserId = currentUser.id
            let parentPostId = parent.id
            let parentRoomId = parent.roomId.uuidString
            let replyPreview = reply.content   // snapshot for the
            // notification row preview ("NavyBull replied: '…'").
            // Stored denormalized as `notifications.preview_text` so
            // the alerts list renders without an extra fetch.
            Task {
                do {
                    try await AppNotificationService.shared.createNotification(
                        userId: recipientUserId,
                        type: .reply,
                        sourceUserId: sourceUserId,
                        postId: parentPostId,
                        roomId: parentRoomId,
                        previewText: replyPreview
                    )
                } catch {
                    logger.error("⚠️ RemoteChatService.createReply: reply-notification insert failed (non-fatal — reply still posted) — \(error)")
                }
            }

            return reply
        } catch let error as RemoteChatError {
            throw error
        } catch {
            logger.error("❌ RemoteChatService.createReply: insert FAILED — \(error)")
            throw RemoteChatError.networkError(error)
        }
    }

    // MARK: - User upsert
    //
    // posts.user_id references users.id, so a fresh device that has never
    // upserted itself into the `users` table will get a FK violation on its
    // first post. This helper guarantees the row exists before we insert.
    // Idempotent and cached for the session.

    private func ensureCurrentUserExists() async throws {
        if hasEnsuredUser { return }

        guard let client else {
            logger.error("❌ RemoteChatService.ensureCurrentUserExists: Supabase client unavailable")
            throw RemoteChatError.notConfigured
        }

        // Compute non-empty profile values. If UserPreferences fields
        // are empty (fresh install / migration / user cleared a field),
        // fall back to a deterministic value from the user_id so the
        // server never receives a blank string. Persist back to
        // UserPreferences so subsequent reads see the same values.
        let prefs = UserPreferences.shared
        var resolvedUsername = prefs.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedUsername.isEmpty {
            resolvedUsername = Post.deterministicDisplayName(for: currentUser.id)
            prefs.username = resolvedUsername
            logger.debug("🛠 RemoteChatService.ensureCurrentUserExists: UserPreferences.username was empty — backfilled to deterministic '\(resolvedUsername)'")
        }
        var resolvedEmoji = prefs.avatarEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedEmoji.isEmpty {
            resolvedEmoji = Post.deterministicAvatarEmoji(for: currentUser.id)
            prefs.avatarEmoji = resolvedEmoji
            logger.debug("🛠 RemoteChatService.ensureCurrentUserExists: UserPreferences.avatarEmoji was empty — backfilled to deterministic '\(resolvedEmoji)'")
        }
        var resolvedColorHex = prefs.avatarColorHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedColorHex.isEmpty {
            resolvedColorHex = Post.deterministicAvatarColorHex(for: currentUser.id)
            prefs.avatarColorHex = resolvedColorHex
            logger.debug("🛠 RemoteChatService.ensureCurrentUserExists: UserPreferences.avatarColorHex was empty — backfilled to deterministic '\(resolvedColorHex)'")
        }

        let payload = UserUpsert(
            id: currentUser.id,
            username: resolvedUsername,
            avatarEmoji: resolvedEmoji,
            avatarColor: resolvedColorHex
        )

        logger.debug("🔵 RemoteChatService.ensureCurrentUserExists: upserting user \(self.currentUser.id.uuidString) (username: '\(payload.username)', emoji: '\(payload.avatarEmoji)')")

        do {
            try await client
                .from("users")
                .upsert(payload, onConflict: "id")
                .execute()

            hasEnsuredUser = true
            logger.debug("✅ RemoteChatService.ensureCurrentUserExists: user upsert succeeded")

            // Seed authorProfiles for currentUser so any post/reply we
            // create gets decorated with the same identity we just
            // wrote server-side. Without this, the originating device
            // displays its own posts with the anonymous fallback name
            // (e.g. "BlueHawk_a1") because the createPost/createReply
            // path never round-trips through loadAuthorProfile, while
            // every OTHER device sees the resolved username/avatar.
            // Seeding from the upsert payload guarantees both sides
            // converge on the same display.
            authorProfiles[currentUser.id] = AuthorProfile(
                id: currentUser.id,
                username: payload.username,
                avatarEmoji: payload.avatarEmoji,
                avatarColorHex: payload.avatarColor
            )
        } catch {
            logger.error("❌ RemoteChatService.ensureCurrentUserExists: user upsert FAILED")
            logger.debug("    error: \(error)")
            logger.debug("    localized: \(error.localizedDescription)")
            throw RemoteChatError.networkError(error)
        }
    }

    // MARK: - fetchPostsForRoom / fetchPostsForTeam (REAL)

    func fetchPostsForTeam(_ teamId: UUID, sortBy: FeedSortOption) async throws -> [Post] {
        // Legacy entry point — treat as a team-room fetch.
        try await fetchPostsForRoom(.team(teamId), sortBy: sortBy)
    }

    func fetchPostsForRoom(_ room: ChatRoom, sortBy: FeedSortOption) async throws -> [Post] {
        guard let client else {
            logger.error("❌ RemoteChatService.fetchPostsForRoom: Supabase client unavailable")
            throw RemoteChatError.notConfigured
        }

        do {
            // RPC `get_room_posts` is the canonical source of feed order.
            // It joins posts with active vote aggregates server-side and
            // applies the requested sort (new / top / hot) using the same
            // formulas the iOS local re-sort helper mirrors. Rationale:
            // before the RPC, sorting was duplicated client-side and the
            // two formulas would silently drift apart.
            //
            // The returned rows include active vote counts (active_upvotes
            // / active_downvotes), so we don't need a separate
            // fetchVoteCounts roundtrip — one query gives us everything
            // the UI needs.
            let params = GetRoomPostsParams(
                room_id_input: room.roomId.uuidString,
                sort_mode: sortBy.rpcSortMode
            )

            logger.debug("🔵 RemoteChatService.fetchPostsForRoom: calling RPC get_room_posts(room=\(room.roomId.uuidString), sort=\(sortBy.rpcSortMode))")

            let rows: [RoomPostRow] = try await client
                .rpc("get_room_posts", params: params)
                .execute()
                .value

            let undecorated = rows.map { $0.toPost() }

            // Resolve author profiles (batch) BEFORE decorating so every
            // returned post carries consistent identity fields.
            await loadAuthorProfiles(for: undecorated.map { $0.authorId })

            // Decorate with author profile only. Vote counts already came
            // back on each row from the RPC (active aggregates) — no extra
            // round-trip needed.
            let fetched = undecorated.map { decorate($0) }

            // Tripwire — if any post lacks decoration after this point,
            // the View will render the strict placeholder ("Unknown").
            for post in fetched {
                assertDecorated(post, source: "fetchPostsForRoom")
            }

            logger.debug("📊 RemoteChatService.fetchPostsForRoom: RPC returned \(fetched.count) post(s) sorted by \(sortBy.rpcSortMode)")

            // Upsert into the local posts cache so subsequent vote/removeVote
            // calls (which mutate the cached Post in place) find these rows.
            // Cache is unordered — VMs maintain their own sorted view.
            for post in fetched {
                if let index = posts.firstIndex(where: { $0.id == post.id }) {
                    posts[index] = post
                } else {
                    posts.append(post)
                }
            }
            postsSubject.send(posts)

            // Preload this user's votes for the fetched posts so the sync
            // `getUserVote(for:)` lookup is correct after a cold launch.
            await preloadVotes(for: fetched.map { $0.id })

            return fetched
        } catch {
            logger.error("❌ RemoteChatService.fetchPostsForRoom(\(room.roomType):\(room.roomId.uuidString)) failed: \(error.localizedDescription)")
            throw RemoteChatError.networkError(error)
        }
    }

    /// Best-effort fetch of the current user's existing votes for a batch of
    /// post ids. Failures are logged but don't propagate — a missing vote
    /// preload only means the UI shows "no vote" until the user re-votes,
    /// which beats failing the whole post fetch.
    private func preloadVotes(for postIds: [UUID]) async {
        guard let client, !postIds.isEmpty else { return }

        do {
            // Only active votes count as the user's selection. A
            // soft-deleted row (is_active=false) means the user removed
            // their vote — UI should treat the post as unvoted.
            let rows: [VoteRow] = try await client
                .from("votes")
                .select()
                .eq("user_id", value: currentUser.id.uuidString)
                .in("post_id", values: postIds.map { $0.uuidString })
                .eq("is_active", value: "true")
                .execute()
                .value

            for row in rows {
                if let mapped = Self.voteType(fromWire: row.voteType) {
                    userVotes[row.postId] = mapped
                }
            }
            logger.debug("✅ RemoteChatService.preloadVotes: \(rows.count) active vote(s) loaded for \(postIds.count) post(s)")
        } catch {
            logger.error("⚠️ RemoteChatService.preloadVotes failed (non-fatal): \(error)")
        }
    }

    // MARK: - Author profile resolution

    /// Fetch profiles for any author IDs not already in the cache. Best-
    /// effort — failures are logged and the cache simply doesn't get
    /// populated, which leaves the affected posts to fall back to
    /// `Post.anonymousName` / hash-derived avatar in the UI.
    private func loadAuthorProfiles(for authorIds: [UUID]) async {
        guard let client else { return }
        // Always re-fetch — do NOT skip already-cached ids. Profile
        // changes (username/emoji/color edits by another user) only
        // propagate to this device by re-querying public.users, so a
        // session-long cache hit would freeze whatever username was
        // first seen and never reflect later edits. Trade-off: one
        // extra round-trip per fetch when the same authors are
        // already cached. Acceptable: per-room fetches are batched
        // (one query for all unique authors), and refreshes only
        // happen on user-initiated screen loads / refreshes /
        // realtime arrivals — not on a tight loop.
        let unique = Array(Set(authorIds))
        guard !unique.isEmpty else { return }

        logger.debug("🔵 RemoteChatService.loadAuthorProfiles: refreshing \(unique.count) profile(s) — cache had \(self.authorProfiles.count) before")
        do {
            let rows: [UserRow] = try await client
                .from("users")
                .select("id, username, avatar_emoji, avatar_color")
                .in("id", values: unique.map { $0.uuidString })
                .execute()
                .value

            for row in rows {
                // Backfill any blank fields with deterministic values
                // derived from row.id (NOT UUID.hashValue — see Post
                // for the rationale). Historical rows where username
                // was inserted as '' will all map to the same name on
                // every device because the bytes of the UUID are
                // identical across processes.
                let trimmedUsername = row.username.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedEmoji = row.avatarEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedColor = row.avatarColor.trimmingCharacters(in: .whitespacesAndNewlines)

                let resolvedUsername = trimmedUsername.isEmpty
                    ? Post.deterministicDisplayName(for: row.id)
                    : trimmedUsername
                let resolvedEmoji = trimmedEmoji.isEmpty
                    ? Post.deterministicAvatarEmoji(for: row.id)
                    : trimmedEmoji
                let resolvedColor = trimmedColor.isEmpty
                    ? Post.deterministicAvatarColorHex(for: row.id)
                    : trimmedColor

                if trimmedUsername.isEmpty || trimmedEmoji.isEmpty || trimmedColor.isEmpty {
                    logger.error("🛠 RemoteChatService.loadAuthorProfiles: row \(row.id.uuidString) had blank fields — backfilled deterministically (username='\(resolvedUsername)' emoji='\(resolvedEmoji)' color='\(resolvedColor)')")
                }

                authorProfiles[row.id] = AuthorProfile(
                    id: row.id,
                    username: resolvedUsername,
                    avatarEmoji: resolvedEmoji,
                    avatarColorHex: resolvedColor
                )
            }
            logger.debug("✅ RemoteChatService.loadAuthorProfiles: resolved \(rows.count)/\(unique.count) profile(s) — cache now \(self.authorProfiles.count)")

            // Any IDs we asked for but got no row back for are missing
            // server-side entirely. Seed the cache with a fully
            // deterministic profile so cross-device renders stay
            // identical even when the users row never existed.
            let resolvedIds = Set(rows.map { $0.id })
            let unresolved = unique.filter { !resolvedIds.contains($0) }
            for missingId in unresolved {
                authorProfiles[missingId] = AuthorProfile(
                    id: missingId,
                    username: Post.deterministicDisplayName(for: missingId),
                    avatarEmoji: Post.deterministicAvatarEmoji(for: missingId),
                    avatarColorHex: Post.deterministicAvatarColorHex(for: missingId)
                )
                logger.error("🛠 RemoteChatService.loadAuthorProfiles: \(missingId.uuidString) had no users row — seeded deterministic profile so all devices render identically")
            }
        } catch {
            logger.error("⚠️ RemoteChatService.loadAuthorProfiles failed (non-fatal — UI will use deterministic fallback): \(error)")
        }
    }

    /// Single-author convenience — used by the realtime path so each
    /// inserted post gets its author resolved without batching.
    private func loadAuthorProfile(for authorId: UUID) async {
        await loadAuthorProfiles(for: [authorId])
    }

    /// Return a copy of `post` with the cached author profile fields
    /// merged in. Falls back to deterministic UUID-byte-derived values
    /// when the cache has nothing — guarantees every emitted post
    /// carries a non-empty identity, so cross-device displays converge
    /// on the same name/emoji/color even if `loadAuthorProfile` was
    /// never called for this author (defense-in-depth: that path
    /// shouldn't normally happen since every emission site precedes
    /// decorate with a profile load).
    private func decorate(_ post: Post) -> Post {
        var copy = post
        if let profile = authorProfiles[post.authorId] {
            copy.authorUsername = profile.username
            copy.authorAvatarEmoji = profile.avatarEmoji
            copy.authorAvatarColorHex = profile.avatarColorHex
        } else {
            copy.authorUsername = Post.deterministicDisplayName(for: post.authorId)
            copy.authorAvatarEmoji = Post.deterministicAvatarEmoji(for: post.authorId)
            copy.authorAvatarColorHex = Post.deterministicAvatarColorHex(for: post.authorId)
        }
        return copy
    }

    /// Verify a post about to be returned / emitted carries decoration.
    /// Logs `❌ Missing author decoration` when any of the three required
    /// fields is nil/empty. Returns the post unchanged (callers continue
    /// the original flow). Acts as a single tripwire across every code
    /// path that hands a Post to the UI: cold-start fetches, realtime
    /// inserts, create/reply round-trips. If the log fires, the View
    /// will render the strict placeholder for that row.
    @discardableResult
    private func assertDecorated(_ post: Post, source: String) -> Post {
        let usernameMissing = (post.authorUsername?.isEmpty ?? true)
        let emojiMissing = (post.authorAvatarEmoji?.isEmpty ?? true)
        let colorMissing = (post.authorAvatarColorHex?.isEmpty ?? true)
        if usernameMissing || emojiMissing || colorMissing {
            logger.error("❌ Missing author decoration for post id=\(post.id.uuidString) user_id=\(post.authorId.uuidString) source=\(source) username_missing=\(usernameMissing) emoji_missing=\(emojiMissing) color_missing=\(colorMissing)")
        }
        return post
    }

    // MARK: - Realtime post subscription
    //
    // Subscribes to Postgres INSERT events on the `posts` table and fans
    // each new post out via `postsSubject` + `notificationSubject`. Single-
    // team callers use a server-side `team_id=eq.<uuid>` filter. Multi-team
    // callers (e.g. GameRoom with home + away) subscribe without a server
    // filter and we filter client-side against `subscribedTeamIds`. Either
    // way, posts already in the local cache are skipped to avoid double-
    // emitting the local user's own newly-created post.

    func subscribeToPosts(room: ChatRoom) async {
        let key = room.roomId.uuidString
        let kind = room.roomType
        logger.debug("🔵 RemoteChatService.subscribeToPosts: ENTRY room=\(kind):\(key)")

        guard let client else {
            logger.error("⚠️ RemoteChatService.subscribeToPosts: client unavailable, returning without subscribing")
            return
        }

        if postSubscriptions[key] != nil {
            logger.debug("ℹ️ RemoteChatService.subscribeToPosts: EARLY RETURN — already subscribed to '\(key)' (registry has \(self.postSubscriptions.count) active scope(s))")
            return
        }

        logger.debug("🔵 RemoteChatService.subscribeToPosts: creating channel '\(key)'")
        let channel = client.realtimeV2.channel(key)

        // Always server-side filter on room_id — uniform across all room
        // kinds (team / game / trending). No more multi-team client-side
        // fallback path.
        let filter = "room_id=eq.\(key)"
        logger.debug("🔵 RemoteChatService.subscribeToPosts: server filter = '\(filter)'")
        let insertions = channel.postgresChange(InsertAction.self,
                                                 schema: "public",
                                                 table: "posts",
                                                 filter: filter)

        logger.debug("🔵 RemoteChatService.subscribeToPosts: calling channel.subscribe() for '\(key)' …")
        await channel.subscribe()
        logger.debug("✅ RemoteChatService.subscribeToPosts: channel.subscribe() returned for '\(key)' — channel.status=\(String(describing: channel.status))")

        logger.debug("🔵 RemoteChatService.subscribeToPosts: spawning listener task for '\(key)'")
        let listenerTask = Task { [weak self] in
            logger.debug("🟢 RemoteChatService.listener[\(key)]: STARTED — entering for-await loop")
            var eventCount = 0
            for await insertion in insertions {
                eventCount += 1
                logger.debug("📥 RemoteChatService.listener[\(key)]: event #\(eventCount) received from stream")
                guard let self else {
                    logger.error("⚠️ RemoteChatService.listener[\(key)]: self deallocated, exiting loop after \(eventCount) event(s)")
                    return
                }
                await self.handlePostInserted(insertion, scopeRoom: room)
            }
            logger.debug("🟡 RemoteChatService.listener[\(key)]: EXITED for-await loop after \(eventCount) event(s) (stream finished or task cancelled)")
        }

        let watcherTask = watchChannelStatus(channel: channel, roomId: room.roomId, label: "posts")

        postSubscriptions[key] = PostSubscription(
            channel: channel,
            listenerTask: listenerTask,
            watcherTask: watcherTask,
            roomId: room.roomId
        )
        logger.debug("✅ RemoteChatService.subscribeToPosts: DONE for '\(key)' — registry now has \(self.postSubscriptions.count) active scope(s)")

        // Open the matching votes subscription so vote count updates
        // from other devices flow into this room live.
        await subscribeToVotesForRoom(room)
    }

    func unsubscribeFromPostScope(room: ChatRoom) async {
        let key = room.roomId.uuidString

        // Tear down votes first so any in-flight vote events stop landing
        // before posts go away.
        await unsubscribeFromVotesForRoom(room)

        guard let subscription = postSubscriptions.removeValue(forKey: key) else {
            logger.debug("ℹ️ RemoteChatService.unsubscribeFromPostScope: no active subscription for '\(key)', skipping")
            return
        }

        logger.debug("🔵 RemoteChatService.unsubscribeFromPostScope: tearing down '\(key)'")
        // Cancel watcher BEFORE removing the channel so the resulting
        // `.unsubscribed` status doesn't get interpreted as a network drop.
        subscription.watcherTask.cancel()
        subscription.listenerTask.cancel()

        if let client {
            await client.realtimeV2.removeChannel(subscription.channel)
        }
        logger.debug("✅ RemoteChatService.unsubscribeFromPostScope: '\(key)' removed")
    }

    // MARK: - Realtime votes
    //
    // Per-room channel filtered server-side by `room_id=eq.<scope>`. Each
    // INSERT / UPDATE / DELETE on the `votes` table flows through
    // `handleVoteAction`, which computes a delta directly from the event
    // payload (no immediate refetch — refetching `posts.upvotes` /
    // `posts.downvotes` would re-introduce the stale-trigger flicker the
    // soft-delete model exists to avoid).
    //
    // Delta math is `newContribution - oldContribution`, where contribution
    // is `(active && type==up) → +1 up` / `(active && type==down) → +1 down`
    // / else 0. This single formula handles every transition:
    //   • INSERT(active=true)            → +1 to up or down
    //   • UPDATE(active true → false)    → -1 (removeVote)
    //   • UPDATE(active false → true)    → +1 (re-vote after soft-delete)
    //   • UPDATE(vote_type swap)         → -1 from one side, +1 to the other
    //   • DELETE                         → fallback to delayed sanity-check
    //                                       refetch (oldRecord on DELETE
    //                                       only carries the primary key)
    //
    // Own-user echo is suppressed (the optimistic mutation in
    // `applyVoteLocally` already wrote the delta locally). A delayed
    // sanity-check via `refetchPostCounts` runs ~1.5s after every event;
    // it re-aggregates from the `votes` table and silently corrects any
    // drift (no emit if the cache already matches).

    private func subscribeToVotesForRoom(_ room: ChatRoom) async {
        guard let client else {
            logger.error("⚠️ RemoteChatService.subscribeToVotes: client unavailable")
            return
        }

        let key = room.roomId.uuidString
        if voteSubscriptions[key] != nil {
            logger.debug("ℹ️ RemoteChatService.subscribeToVotes: already subscribed to votes for '\(key)', skipping")
            return
        }

        let channelName = "votes:\(key)"
        let filter = "room_id=eq.\(key)"
        logger.debug("🔵 RemoteChatService.subscribeToVotes: creating votes channel '\(channelName)' with server filter '\(filter)'")
        let channel = client.realtimeV2.channel(channelName)

        // Three streams under one channel — Postgres realtime emits each
        // change kind as its own action type. Server-side filter on
        // `room_id` means only votes for posts in THIS room arrive,
        // mirroring the posts subscription's per-room filter.
        let inserts = channel.postgresChange(InsertAction.self,
                                              schema: "public",
                                              table: "votes",
                                              filter: filter)
        let updates = channel.postgresChange(UpdateAction.self,
                                              schema: "public",
                                              table: "votes",
                                              filter: filter)
        let deletes = channel.postgresChange(DeleteAction.self,
                                              schema: "public",
                                              table: "votes",
                                              filter: filter)

        await channel.subscribe()
        logger.debug("✅ RemoteChatService.subscribeToVotes: votes channel for '\(key)' subscribed — channel.status=\(String(describing: channel.status))")

        // Single parent task spawning three child loops via TaskGroup,
        // so cancellation propagates to all three when the room closes.
        let listenerTask = Task { [weak self] in
            logger.debug("🟢 RemoteChatService.votesListener[\(key)]: STARTED")
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await action in inserts {
                        guard let self else { return }
                        await self.handleVoteAction(kind: "INSERT",
                                                    oldRecord: nil,
                                                    newRecord: action.record,
                                                    scopeRoomId: room.roomId)
                    }
                }
                group.addTask {
                    for await action in updates {
                        guard let self else { return }
                        await self.handleVoteAction(kind: "UPDATE",
                                                    oldRecord: action.oldRecord,
                                                    newRecord: action.record,
                                                    scopeRoomId: room.roomId)
                    }
                }
                group.addTask {
                    for await action in deletes {
                        guard let self else { return }
                        // Raw oldRecord BEFORE any decode — diagnoses the
                        // case where REPLICA IDENTITY FULL isn't actually
                        // active and the SDK delivers only the primary key
                        // (which would prevent the post_id / vote_type read
                        // the delta path needs).
                        logger.debug("🗑 RemoteChatService.votesListener[\(key)]: DELETE raw oldRecord = \(action.oldRecord)")
                        await self.handleVoteAction(kind: "DELETE",
                                                    oldRecord: action.oldRecord,
                                                    newRecord: nil,
                                                    scopeRoomId: room.roomId)
                    }
                }
            }
            logger.debug("🟡 RemoteChatService.votesListener[\(key)]: EXITED")
        }

        let watcherTask = watchChannelStatus(channel: channel, roomId: room.roomId, label: "votes")

        voteSubscriptions[key] = VoteSubscription(
            channel: channel,
            listenerTask: listenerTask,
            watcherTask: watcherTask,
            roomId: room.roomId
        )
    }

    private func unsubscribeFromVotesForRoom(_ room: ChatRoom) async {
        let key = room.roomId.uuidString
        guard let subscription = voteSubscriptions.removeValue(forKey: key) else { return }

        logger.debug("🔵 RemoteChatService.unsubscribeFromVotes: tearing down votes channel for '\(key)'")
        subscription.watcherTask.cancel()
        subscription.listenerTask.cancel()
        if let client {
            await client.realtimeV2.removeChannel(subscription.channel)
        }
        logger.debug("✅ RemoteChatService.unsubscribeFromVotes: '\(key)' removed")
    }

    // MARK: - User profile realtime subscription

    /// Open the single app-wide UPDATE subscription on
    /// public.users. Idempotent — repeat calls (from MainTabView's
    /// `.task` and `scenePhase == .active` hooks) are no-ops once
    /// the channel is established. The subscription stays alive
    /// for the singleton's lifetime; there's no `stop` counterpart
    /// because identity updates are app-wide concerns and outlive
    /// any specific view.
    func startUserProfilesSubscription() async {
        if userProfilesSubscribed {
            logger.debug("ℹ️ RemoteChatService.startUserProfilesSubscription: already subscribed, no-op")
            return
        }
        userProfilesSubscribed = true   // set BEFORE awaiting so a
        // concurrent second call from .active during initial .task
        // sees us as already starting.

        guard let client else {
            logger.error("❌ RemoteChatService.startUserProfilesSubscription: Supabase client unavailable")
            userProfilesSubscribed = false   // allow retry next time
            return
        }

        let channel = client.realtimeV2.channel("user-profiles-updates")
        // No server-side filter — every user UPDATE is potentially
        // interesting (any user might be the author of a post we
        // have cached, or the source of a notification we have
        // visible). The fan-out is small (a single decoded row +
        // an in-memory cache walk).
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "users"
        )

        await channel.subscribe()
        logger.debug("✅ RemoteChatService.startUserProfilesSubscription: channel subscribed (status=\(String(describing: channel.status)))")

        let task = Task { [weak self] in
            for await action in updates {
                guard let self else { return }
                await self.handleUserProfileUpdate(action)
            }
            logger.debug("🟡 RemoteChatService.userProfiles listener exited")
        }

        // Status watcher — see the per-room equivalent in
        // `watchChannelStatus(channel:roomId:label:)`. Detects
        // mid-session drops and triggers reconnect so the user-
        // profiles channel stays alive without depending on a
        // background→foreground cycle.
        let watcher = watchUserProfilesChannelStatus(channel: channel)

        userProfilesChannel = channel
        userProfilesListenerTask = task
        userProfilesWatcherTask = watcher
    }

    /// Per-channel watcher for the user-profiles subscription.
    /// Triggers `attemptUserProfilesReconnect` whenever the channel
    /// flips to `.unsubscribed` outside of an intentional teardown.
    /// Cancelled and re-created on each reconnect cycle so it
    /// always points at the current channel.
    private func watchUserProfilesChannelStatus(channel: RealtimeChannelV2) -> Task<Void, Never> {
        return Task { [weak self] in
            logger.debug("🟣 RemoteChatService.userProfilesWatcher: STARTED — initial status=\(String(describing: channel.status))")
            for await newStatus in channel.statusChange {
                logger.debug("🟣 RemoteChatService.userProfilesWatcher: status → \(String(describing: newStatus))")

                if Task.isCancelled {
                    logger.debug("🟣 RemoteChatService.userProfilesWatcher: cancelled, exiting")
                    return
                }
                guard let self else { return }

                // Treat `.unsubscribed` as a drop — the SDK emits
                // this for closed/errored conditions too. Any other
                // status (`.subscribing`, `.subscribed`) is normal
                // lifecycle and gets ignored.
                if newStatus == .unsubscribed {
                    logger.error("⚠️ RemoteChatService.userProfilesWatcher: channel DROPPED — triggering reconnect")
                    await self.attemptUserProfilesReconnect(trigger: "watcher")
                }
            }
            logger.debug("🟣 RemoteChatService.userProfilesWatcher: stream finished, EXITED")
        }
    }

    /// Tear down and re-establish the user-profiles channel.
    /// Idempotent under reentrancy via
    /// `userProfilesReconnectInFlight`. Mirrors
    /// `attemptReconnect(roomId:trigger:)` but for the single
    /// app-wide channel (no per-room scoping).
    private func attemptUserProfilesReconnect(trigger: String) async {
        guard !userProfilesReconnectInFlight else {
            logger.debug("🔁 RemoteChatService.attemptUserProfilesReconnect (\(trigger)): already in flight, skipping")
            return
        }
        userProfilesReconnectInFlight = true
        defer { userProfilesReconnectInFlight = false }

        logger.debug("🔁 RemoteChatService.attemptUserProfilesReconnect (\(trigger)): tearing down + re-subscribing")

        // Cancel the in-flight tasks and remove the dropped channel
        // so we can build a clean replacement. Each cancel() just
        // sets the flag — the for-await loops exit on next await.
        userProfilesWatcherTask?.cancel()
        userProfilesWatcherTask = nil
        userProfilesListenerTask?.cancel()
        userProfilesListenerTask = nil
        if let dropped = userProfilesChannel, let client {
            await client.realtimeV2.removeChannel(dropped)
        }
        userProfilesChannel = nil
        // Reset the idempotency flag so the next start() actually
        // re-subscribes (rather than no-op'ing on the prior stale
        // value).
        userProfilesSubscribed = false

        await startUserProfilesSubscription()

        let recoveredStatus = String(describing: userProfilesChannel?.status as Any)
        if userProfilesChannel != nil {
            logger.debug("✅ RemoteChatService.attemptUserProfilesReconnect (\(trigger)): SUCCEEDED — new channel status=\(recoveredStatus)")
        } else {
            logger.error("❌ RemoteChatService.attemptUserProfilesReconnect (\(trigger)): FAILED to re-establish channel — next foreground / scenePhase trigger will retry")
        }
    }

    private func handleUserProfileUpdate(_ action: UpdateAction) async {
        let row: UserRow
        do {
            row = try action.decodeRecord(as: UserRow.self, decoder: Self.realtimeDecoder)
        } catch {
            logger.error("❌ RemoteChatService.handleUserProfileUpdate: decode failed — \(error)")
            return
        }

        // Resolve the same way loadAuthorProfiles does — backfill
        // any blank fields with deterministic values so cross-
        // device renders stay consistent even when a user has a
        // partially-filled profile row.
        let trimmedUsername = row.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = row.avatarEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedColor = row.avatarColor.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUsername = trimmedUsername.isEmpty
            ? Post.deterministicDisplayName(for: row.id)
            : trimmedUsername
        let resolvedEmoji = trimmedEmoji.isEmpty
            ? Post.deterministicAvatarEmoji(for: row.id)
            : trimmedEmoji
        let resolvedColor = trimmedColor.isEmpty
            ? Post.deterministicAvatarColorHex(for: row.id)
            : trimmedColor

        logger.debug("📨 RemoteChatService.handleUserProfileUpdate: user=\(row.id.uuidString) username='\(resolvedUsername)' emoji='\(resolvedEmoji)' color='\(resolvedColor)'")

        // 1. Update the canonical author cache.
        authorProfiles[row.id] = AuthorProfile(
            id: row.id,
            username: resolvedUsername,
            avatarEmoji: resolvedEmoji,
            avatarColorHex: resolvedColor
        )

        // 2. Walk cached posts and patch any with this authorId.
        //    Emit .postUpdated for each so room/thread VMs that
        //    listen to notificationPublisher re-render the
        //    affected rows live.
        var patchedCount = 0
        for index in posts.indices where posts[index].authorId == row.id {
            posts[index].authorUsername = resolvedUsername
            posts[index].authorAvatarEmoji = resolvedEmoji
            posts[index].authorAvatarColorHex = resolvedColor
            let patched = posts[index]
            notificationSubject.send(.postUpdated(patched))
            patchedCount += 1
        }
        if patchedCount > 0 {
            postsSubject.send(posts)
            logger.debug("    🔄 patched \(patchedCount) cached post(s) for authorId=\(row.id.uuidString)")
        }

        // 3. Republish to subscribers (e.g., NotificationsViewModel)
        //    via Combine. They update their own per-screen caches.
        let appProfile = AppUserProfile(
            id: row.id,
            username: resolvedUsername,
            avatarEmoji: resolvedEmoji,
            avatarColor: resolvedColor
        )
        userProfileUpdatesSubject.send(appProfile)
    }

    // MARK: - Realtime reconnect
    //
    // Two reconnect triggers:
    //
    //   1. Per-channel status watcher — fires `attemptReconnect(roomId:)`
    //      when `channel.statusChange` flips to `.unsubscribed` outside of
    //      an intentional teardown (the unsubscribe paths cancel the
    //      watcher first, so they never trip this path).
    //
    //   2. App foreground — `reconnectAllChannels()` is called from the
    //      `JumboIOSApp` `scenePhase = .active` hook, force-resubscribing
    //      every channel in the registry. Catches the case where the
    //      WebSocket dropped silently while backgrounded.
    //
    // Both routes converge on `attemptReconnect(roomId:)` which is
    // guarded by `reconnectsInFlight` so duplicate triggers (posts and
    // votes watchers firing in the same window) only run one cycle per
    // room.

    /// Spawns a Task that observes the channel's status changes and
    /// triggers reconnect when the channel becomes `.unsubscribed`
    /// outside our control. Returned task should be stored in the
    /// subscription registry and cancelled in the unsubscribe path.
    private func watchChannelStatus(channel: RealtimeChannelV2,
                                     roomId: UUID,
                                     label: String) -> Task<Void, Never> {
        let key = roomId.uuidString
        return Task { [weak self] in
            logger.debug("🟣 RemoteChatService.watcher[\(key)/\(label)]: STARTED — initial status=\(String(describing: channel.status))")
            for await newStatus in channel.statusChange {
                logger.debug("🟣 RemoteChatService.watcher[\(key)/\(label)]: status → \(String(describing: newStatus))")

                // Bail if cancelled mid-await.
                if Task.isCancelled {
                    logger.debug("🟣 RemoteChatService.watcher[\(key)/\(label)]: cancelled, exiting")
                    return
                }

                guard let self else { return }

                if newStatus == .unsubscribed {
                    // Double-check the registry before reconnecting — if
                    // an explicit teardown removed the entry while this
                    // status was in flight, skip.
                    let stillActive = (self.postSubscriptions[key] != nil
                                       || self.voteSubscriptions[key] != nil)
                    guard stillActive else {
                        logger.debug("🟣 RemoteChatService.watcher[\(key)/\(label)]: no active subscription in registry — intentional teardown, no reconnect")
                        return
                    }
                    await self.attemptReconnect(roomId: roomId, trigger: "watcher.\(label)")
                }
            }
            logger.debug("🟣 RemoteChatService.watcher[\(key)/\(label)]: stream finished, EXITED")
        }
    }

    /// Re-subscribe the post and vote channels for `roomId`. Idempotent
    /// per room via `reconnectsInFlight` — concurrent triggers collapse
    /// into one cycle. Three attempts with exponential backoff (1s, 2s,
    /// 4s); on final failure logs and leaves the channels in whatever
    /// state the SDK landed them, ready for the next trigger to retry.
    private func attemptReconnect(roomId: UUID, trigger: String) async {
        let key = roomId.uuidString

        guard !reconnectsInFlight.contains(roomId) else {
            logger.debug("🔁 RemoteChatService.attemptReconnect[\(key)] (\(trigger)): already in flight, skipping")
            return
        }
        reconnectsInFlight.insert(roomId)
        defer { reconnectsInFlight.remove(roomId) }

        let postsChannel = postSubscriptions[key]?.channel
        let votesChannel = voteSubscriptions[key]?.channel

        guard postsChannel != nil || votesChannel != nil else {
            logger.debug("🔁 RemoteChatService.attemptReconnect[\(key)] (\(trigger)): no channels in registry, nothing to reconnect")
            return
        }

        logger.debug("🔁 RemoteChatService.attemptReconnect[\(key)] (\(trigger)): starting — posts=\(postsChannel != nil ? "yes" : "no") votes=\(votesChannel != nil ? "yes" : "no")")

        var delay: TimeInterval = 1.0
        for attempt in 1...3 {
            if Task.isCancelled {
                logger.debug("🔁 RemoteChatService.attemptReconnect[\(key)]: cancelled mid-retry")
                return
            }

            logger.debug("🔁 RemoteChatService.attemptReconnect[\(key)]: attempt \(attempt)/3")

            if let postsChannel { await postsChannel.subscribe() }
            if let votesChannel { await votesChannel.subscribe() }

            let postsOk = (postsChannel?.status ?? .subscribed) == .subscribed
            let votesOk = (votesChannel?.status ?? .subscribed) == .subscribed

            let postsStatus = String(describing: postsChannel?.status as Any)
            let votesStatus = String(describing: votesChannel?.status as Any)

            if postsOk && votesOk {
                logger.debug("✅ RemoteChatService.attemptReconnect[\(key)]: success on attempt \(attempt) — posts.status=\(postsStatus) votes.status=\(votesStatus)")
                return
            }

            logger.error("⚠️ RemoteChatService.attemptReconnect[\(key)]: attempt \(attempt) incomplete — posts.status=\(postsStatus) votes.status=\(votesStatus)")

            if attempt < 3 {
                logger.debug("🔁 RemoteChatService.attemptReconnect[\(key)]: waiting \(delay)s before retry")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2
            }
        }

        logger.error("❌ RemoteChatService.attemptReconnect[\(key)]: gave up after 3 attempts — channel may stay in dropped state until next foreground or status flip")
    }

    /// App-foreground hook. Force-resubscribe every channel in both
    /// registries in case the WebSocket dropped silently in background.
    /// Called from `JumboIOSApp` on `scenePhase = .active`.
    func reconnectAllChannels() async {
        let postKeys = Array(postSubscriptions.keys)
        let voteKeys = Array(voteSubscriptions.keys)
        let allRoomIds = Set(postSubscriptions.values.map { $0.roomId })
                            .union(voteSubscriptions.values.map { $0.roomId })

        logger.debug("🔁 RemoteChatService.reconnectAllChannels: forcing re-subscribe across \(postKeys.count) post + \(voteKeys.count) vote channel(s) covering \(allRoomIds.count) room(s)")

        for roomId in allRoomIds {
            await attemptReconnect(roomId: roomId, trigger: "scenePhase.active")
        }
    }

    /// Process a single vote-table change event. Applies a delta directly
    /// to the cached post (no immediate refetch — the votes-table aggregate
    /// query was the source of the 0-flicker). A delayed sanity check runs
    /// ~1.5s later via `refetchPostCounts` to reconcile any drift (e.g.
    /// missed events, double-applied deltas on the originating device).
    ///
    /// For INSERT we read the new vote_type and increment up/down by 1.
    /// For DELETE we read the old vote_type and decrement (clamped at 0).
    /// For UPDATE (vote swap up↔down) we move 1 from one side to the other.
    /// Counts are clamped at 0 so a transient under-count from a missed
    /// preceding event can't go negative.
    private func handleVoteAction(kind: String,
                                  oldRecord: JSONObject?,
                                  newRecord: JSONObject?,
                                  scopeRoomId: UUID) async {
        let scopeKey = scopeRoomId.uuidString
        logger.debug("📊 RemoteChatService.votesListener[\(scopeKey)]: \(kind) event received")

        // DELETE gets its own dedicated path (partial-decode fallback,
        // explicit per-field logs, sanity-check refetch when fields are
        // missing). All the information for a DELETE lives in oldRecord,
        // and oldRecord is the field most likely to arrive incomplete
        // (REPLICA IDENTITY misconfig, RLS column hiding, etc.), so it
        // warrants the extra structure.
        if kind == "DELETE" {
            await handleVoteDelete(oldRecord: oldRecord,
                                   scopeRoomId: scopeRoomId,
                                   scopeKey: scopeKey)
            return
        }

        let oldDecoded = oldRecord.flatMap { decodeVoteEvent($0, kind: kind, slot: "oldRecord", scopeKey: scopeKey) }
        let newDecoded = newRecord.flatMap { decodeVoteEvent($0, kind: kind, slot: "newRecord", scopeKey: scopeKey) }

        // Use whichever record is available to identify the post + room.
        // INSERT only has new, UPDATE has both.
        guard let representative = newDecoded ?? oldDecoded else {
            logger.error("❌ RemoteChatService.votesListener[\(scopeKey)]: \(kind) event had no decodable record, dropping")
            return
        }

        let postId = representative.postId
        logger.debug("    post_id=\(postId.uuidString) user_id=\(representative.userId.uuidString) room_id=\(representative.roomId.uuidString)")

        // Defensive: server filter `room_id=eq.<scope>` already guarantees
        // we only get events for this room. Defense-in-depth in case the
        // filter slips (SDK bug, server config drift, etc.).
        guard representative.roomId == scopeRoomId else {
            logger.error("⚠️ RemoteChatService.votesListener[\(scopeKey)]: defensive REJECT — event.room_id \(representative.roomId.uuidString) does not match scope \(scopeKey)")
            return
        }

        // Same-user echo suppression. `vote(on:)` / `removeVote(from:)`
        // already applied the optimistic delta synchronously via
        // `applyVoteLocally`; a second delta from the realtime echo of
        // our own write would double-count (0→1→2 → corrected back to
        // 1 by the sanity check, which is the visible flicker the user
        // reported). Skip the immediate delta but still schedule the
        // sanity check so any divergence (e.g. server-side adjustment,
        // missed earlier event) gets reconciled silently.
        if representative.userId == currentUser.id {
            logger.debug("↩️ RemoteChatService.votesListener[\(scopeKey)]: own-user echo for post \(postId.uuidString) — skipping delta (optimistic mutation already applied), scheduling sanity check")
            Self.scheduleSanityCheck(service: self, postId: postId, scopeKey: scopeKey)
            return
        }

        // Apply the delta to the cached post. If the post isn't in our
        // local cache (e.g. user hasn't scrolled to a chat that contains
        // it), there's nothing to update — the next `fetchPostsForRoom`
        // will derive the right count from the votes table.
        guard let index = posts.firstIndex(where: { $0.id == postId }) else {
            logger.debug("ℹ️ RemoteChatService.votesListener[\(scopeKey)]: post \(postId.uuidString) not in local cache, skipping delta")
            return
        }

        var updated = posts[index]
        let priorUp = updated.upvotes
        let priorDown = updated.downvotes

        switch kind {
        case "INSERT":
            guard let row = newDecoded else {
                logger.error("⚠️ RemoteChatService.votesListener[\(scopeKey)]: INSERT missing new record, skipping delta")
                return
            }
            // Brand-new vote row. Counts only if it lands in the active
            // state (the normal path — vote() upserts is_active=true). A
            // soft-deleted INSERT (is_active=false) contributes 0.
            let contrib = Self.contribution(active: row.isActive, voteType: Self.voteType(fromWire: row.voteType))
            updated.upvotes = max(0, updated.upvotes + contrib.up)
            updated.downvotes = max(0, updated.downvotes + contrib.down)
            logger.debug("    INSERT contribution: active=\(row.isActive) vote_type='\(row.voteType)' → up\(contrib.up >= 0 ? "+" : "")\(contrib.up) down\(contrib.down >= 0 ? "+" : "")\(contrib.down)")

        case "UPDATE":
            // Soft-delete model: UPDATE covers (a) is_active toggling
            // true→false (removeVote) and false→true (re-vote after
            // soft-delete), AND (b) vote_type swap up↔down on an active
            // row. Reduce all of these to a single delta by computing
            // the contribution before and after, then applying the diff.
            //
            // Requires REPLICA IDENTITY FULL on the votes table so the
            // SDK delivers oldRecord. If oldRecord is missing/stripped,
            // we can't compute the old contribution — defer to the
            // votes-table aggregate sanity check.
            guard let oldRow = oldDecoded, let newRow = newDecoded else {
                logger.error("⚠️ RemoteChatService.votesListener[\(scopeKey)]: UPDATE missing old or new record; deferring to sanity-check refetch")
                Self.scheduleSanityCheck(service: self, postId: postId, scopeKey: scopeKey)
                return
            }
            let oldContrib = Self.contribution(active: oldRow.isActive, voteType: Self.voteType(fromWire: oldRow.voteType))
            let newContrib = Self.contribution(active: newRow.isActive, voteType: Self.voteType(fromWire: newRow.voteType))
            let upDelta = newContrib.up - oldContrib.up
            let downDelta = newContrib.down - oldContrib.down
            updated.upvotes = max(0, updated.upvotes + upDelta)
            updated.downvotes = max(0, updated.downvotes + downDelta)
            logger.debug("    UPDATE contribution: (active=\(oldRow.isActive) type='\(oldRow.voteType)') → (active=\(newRow.isActive) type='\(newRow.voteType)') = up\(upDelta >= 0 ? "+" : "")\(upDelta) down\(downDelta >= 0 ? "+" : "")\(downDelta)")

        default:
            logger.error("⚠️ RemoteChatService.votesListener[\(scopeKey)]: unknown kind '\(kind)', skipping delta")
            return
        }

        posts[index] = updated
        postsSubject.send(posts)
        notificationSubject.send(.postUpdated(updated))

        logger.debug("✅ RemoteChatService.votesListener[\(scopeKey)]: \(kind) delta applied — post \(postId.uuidString) up \(priorUp)→\(updated.upvotes) down \(priorDown)→\(updated.downvotes)")

        // Schedule a delayed reconciliation. The originating device will
        // briefly over-count because applyVoteLocally already wrote the
        // optimistic delta and the realtime echo just added a second one;
        // the sanity check pulls the votes-table aggregate ~1.5s later
        // and corrects only if the local count disagrees.
        Self.scheduleSanityCheck(service: self, postId: postId, scopeKey: scopeKey)
    }

    /// DELETE handler — fallback only. With the soft-delete model
    /// (`removeVote` UPDATEs is_active=false), normal flow never produces
    /// a DELETE event. A DELETE here means an admin SQL hard-delete, a
    /// migration cleanup, or some other out-of-band action. The realtime
    /// payload's oldRecord only carries the primary key (Postgres
    /// realtime SDK behavior — REPLICA IDENTITY FULL doesn't help), so
    /// we can't compute a precise delta. Schedule a delayed votes-table
    /// aggregate refetch so the count still reconciles to truth, and log
    /// the raw payload for debugging.
    private func handleVoteDelete(oldRecord: JSONObject?,
                                  scopeRoomId: UUID,
                                  scopeKey: String) async {
        guard let oldRecord else {
            logger.error("❌ RemoteChatService.votesListener[\(scopeKey)]: DELETE oldRecord was NIL — dropping (unexpected with soft-delete model active)")
            return
        }

        // Best-effort partial decode just to recover post_id for the
        // sanity-check refetch. The strict decoder requires fields the
        // DELETE payload doesn't carry, so it would always fail here.
        let partial: VoteEventPartial?
        do {
            let data = try JSONEncoder().encode(oldRecord)
            partial = try Self.realtimeDecoder.decode(VoteEventPartial.self, from: data)
        } catch {
            logger.error("❌ RemoteChatService.votesListener[\(scopeKey)]: DELETE partial decode failed — \(error)")
            return
        }

        logger.debug("🗑 RemoteChatService.votesListener[\(scopeKey)]: DELETE decoded — post_id=\(partial?.postId?.uuidString ?? "nil") user_id=\(partial?.userId?.uuidString ?? "nil") room_id=\(partial?.roomId?.uuidString ?? "nil") vote_type='\(partial?.voteType ?? "nil")' is_active=\(partial?.isActive.map(String.init) ?? "nil")")

        guard let postId = partial?.postId else {
            logger.error("⚠️ RemoteChatService.votesListener[\(scopeKey)]: DELETE has no post_id — cannot schedule sanity-check; dropping (unexpected hard-delete with primary-key-only payload)")
            return
        }

        logger.debug("ℹ️ RemoteChatService.votesListener[\(scopeKey)]: DELETE post \(postId.uuidString) — soft-delete model means this is unexpected; scheduling votes-table aggregate refetch as fallback")
        Self.scheduleSanityCheck(service: self, postId: postId, scopeKey: scopeKey)
    }

    /// Fire-and-forget delayed reconciliation. Detached `Task` so it
    /// survives the listener cancelling and so multiple events for the
    /// same post don't serialize behind each other.
    private static func scheduleSanityCheck(service: RemoteChatService,
                                            postId: UUID,
                                            scopeKey: String) {
        Task { [weak service] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await service?.refetchPostCounts(for: postId, scopeKey: scopeKey)
        }
    }

    /// Decode a single vote-event JSONObject. Failures are logged and
    /// return nil so the caller can continue with whichever side decoded
    /// (handles the partial-payload edge case on UPDATE without
    /// REPLICA IDENTITY FULL).
    private func decodeVoteEvent(_ record: JSONObject,
                                 kind: String,
                                 slot: String,
                                 scopeKey: String) -> VoteEventRow? {
        do {
            let data = try JSONEncoder().encode(record)
            return try Self.realtimeDecoder.decode(VoteEventRow.self, from: data)
        } catch {
            logger.error("❌ RemoteChatService.votesListener[\(scopeKey)]: \(kind).\(slot) decode failed — \(error)")
            return nil
        }
    }

    /// Delayed sanity check that reconciles the cached upvote/downvote
    /// totals against the votes-table aggregate. Used as a follow-up to
    /// the immediate event-driven delta in `handleVoteAction` — the
    /// delta path is what the user sees; this is the cleanup that fixes
    /// any drift (originating-device double-count, missed event from a
    /// realtime gap, etc.).
    ///
    /// Important: ONLY emits if the local cache disagrees with the
    /// aggregate. A matching aggregate is silently noted and nothing is
    /// pushed downstream — that's the contract that prevents the old
    /// "reset to 0" flicker the unconditional refetch caused.
    ///
    /// Why we count rows in `votes` rather than reading
    /// `posts.upvotes` / `posts.downvotes`:
    ///   The server-side trigger that maintains those columns has proven
    ///   unreliable (counts at 0 even when vote rows clearly exist).
    ///   Counting the rows themselves is the only source of truth that
    ///   consistently matches reality.
    private func refetchPostCounts(for postId: UUID, scopeKey: String) async {
        guard client != nil else { return }

        let cachedUp = posts.first(where: { $0.id == postId })?.upvotes
        let cachedDown = posts.first(where: { $0.id == postId })?.downvotes
        logger.debug("🕐 RemoteChatService.refetchPostCounts[\(scopeKey)]: sanity-check START — post \(postId.uuidString) cached up=\(cachedUp.map(String.init) ?? "nil") down=\(cachedDown.map(String.init) ?? "nil")")

        do {
            let counts = try await fetchVoteCounts(for: [postId])
            let aggregated = counts[postId] ?? (up: 0, down: 0)

            guard let index = posts.firstIndex(where: { $0.id == postId }) else {
                logger.debug("ℹ️ RemoteChatService.refetchPostCounts[\(scopeKey)]: post \(postId.uuidString) no longer in local cache — nothing to reconcile")
                return
            }

            let oldUp = posts[index].upvotes
            let oldDown = posts[index].downvotes

            guard oldUp != aggregated.up || oldDown != aggregated.down else {
                logger.debug("✓ RemoteChatService.refetchPostCounts[\(scopeKey)]: sanity-check OK — local up=\(oldUp) down=\(oldDown) matches votes-table aggregate, no emit")
                return
            }

            var updated = posts[index]
            updated.upvotes = aggregated.up
            updated.downvotes = aggregated.down
            posts[index] = updated
            postsSubject.send(posts)
            notificationSubject.send(.postUpdated(updated))

            logger.debug("🛠 RemoteChatService.refetchPostCounts[\(scopeKey)]: sanity-check CORRECTED post \(postId.uuidString) — up \(oldUp)→\(updated.upvotes) down \(oldDown)→\(updated.downvotes)")
        } catch {
            logger.error("❌ RemoteChatService.refetchPostCounts[\(scopeKey)]: sanity-check failed for \(postId.uuidString) — \(error)")
        }
    }

    /// Pull all vote rows for the given post IDs from the `votes` table and
    /// aggregate them into (up, down) counts per post. The single source of
    /// truth for vote totals — both cold-start (`fetchPostsForRoom`) and
    /// realtime updates (`refetchPostCounts`) flow through here, so the two
    /// paths can never disagree about how many votes a post actually has.
    ///
    /// Posts with zero votes don't appear in the returned dictionary;
    /// callers should treat absence as `(0, 0)`.
    private func fetchVoteCounts(for postIds: [UUID]) async throws -> [UUID: (up: Int, down: Int)] {
        guard let client, !postIds.isEmpty else { return [:] }

        // Only active votes contribute to counts. Soft-deleted rows
        // (is_active=false) sit on the table to deliver realtime UPDATE
        // events but should never be counted again.
        let rows: [VoteRow] = try await client
            .from("votes")
            .select("user_id, post_id, vote_type, is_active")
            .in("post_id", values: postIds.map { $0.uuidString })
            .eq("is_active", value: "true")
            .execute()
            .value

        var counts: [UUID: (up: Int, down: Int)] = [:]
        for row in rows {
            var current = counts[row.postId] ?? (up: 0, down: 0)
            // CHECK constraint guarantees 'up' / 'down' only. Anything
            // else is a server-side bug worth ignoring loudly via the
            // default-skip rather than silently miscategorizing.
            switch row.voteType.lowercased() {
            case "up":   current.up += 1
            case "down": current.down += 1
            default:     break
            }
            counts[row.postId] = current
        }
        return counts
    }

    private func handlePostInserted(_ action: InsertAction, scopeRoom: ChatRoom) async {
        let scopeKey = scopeRoom.roomId.uuidString
        logger.debug("📨 RemoteChatService.handlePostInserted [\(scopeKey)]: ENTRY")

        // Raw payload — the dictionary the SDK received before our typed
        // decode. Helps diagnose schema drift, missing/null columns,
        // unexpected type coercions, etc.
        logger.debug("    raw record: \(action.record)")

        let row: PostRow
        do {
            row = try action.decodeRecord(as: PostRow.self, decoder: Self.realtimeDecoder)
        } catch {
            logger.error("❌ RemoteChatService.handlePostInserted [\(scopeKey)]: decode failed — \(error)")
            return
        }

        logger.debug("    decoded post.id=\(row.id.uuidString) room_id=\(row.roomId?.uuidString ?? "nil") room_type=\(row.roomType ?? "nil") team_id=\(row.teamId?.uuidString ?? "nil") user_id=\(row.userId.uuidString) parent_id=\(row.parentId?.uuidString ?? "nil")")

        let undecorated = row.toPost()

        // Belt-and-suspenders client-side filter. The server filter
        // `room_id=eq.<uuid>` already does this authoritatively; the local
        // check catches anything that slips past a misconfigured filter.
        guard undecorated.belongs(to: scopeRoom) else {
            logger.debug("    client-side filter: REJECT — post.room_id \(undecorated.roomId.uuidString) does not belong to scope \(scopeKey)")
            return
        }
        logger.debug("    client-side filter: PASS — post.belongs(to: \(scopeRoom.roomType) scope)")

        // Resolve author profile so the realtime-inserted post carries
        // the same username/avatar/color the original device displays.
        await loadAuthorProfile(for: undecorated.authorId)
        let post = decorate(undecorated)
        assertDecorated(post, source: "handlePostInserted[\(scopeKey)]")

        // Single ingest path — same code that createPost uses. Dedupe
        // (own-echo vs. cross-scope overlap) and the reply→parent
        // count bump live in there so both flows agree.
        ingestPost(post, scopeKey: scopeKey)
    }

    /// Single insertion path for both `createPost` (originating device)
    /// and `handlePostInserted` (realtime echo / cross-device). Idempotent
    /// — re-running for an already-cached post is a silent no-op, which
    /// is what we want when the originating device's createPost runs
    /// first and the realtime echo arrives second.
    ///
    /// Reply handling: when `post.parentId` is set, find the parent in
    /// the cache and bump its `replyCount` by 1, then emit `.postUpdated`
    /// so feed VMs re-render the reply badge live. Bump only fires when
    /// this insert was new (i.e., we passed the dedupe check) so the
    /// originating device's optimistic insert and the realtime echo
    /// don't double-count.
    private func ingestPost(_ post: Post, scopeKey: String? = nil) {
        let label = scopeKey.map { "[\($0)]" } ?? ""

        guard !posts.contains(where: { $0.id == post.id }) else {
            logger.debug("ℹ️ RemoteChatService.ingestPost\(label): \(post.id.uuidString) DUPLICATE — already in cache (\(self.posts.count) total), no-op")
            return
        }

        posts.insert(post, at: 0)
        postsSubject.send(posts)
        notificationSubject.send(.newPost(post))
        logger.debug("✅ RemoteChatService.ingestPost\(label): EMITTED .newPost for \(post.id.uuidString) (cache now \(self.posts.count))")

        // Reply: bump parent.replyCount + emit .postUpdated so any feed
        // VM showing the parent live-updates its reply badge. The bump
        // is local — the server-side `update_reply_count` trigger keeps
        // posts.reply_count authoritative; the next room fetch will
        // reconcile if the local increment ever drifts.
        if let parentId = post.parentId,
           let parentIndex = posts.firstIndex(where: { $0.id == parentId }) {
            posts[parentIndex].replyCount += 1
            let updatedParent = posts[parentIndex]
            postsSubject.send(posts)
            notificationSubject.send(.postUpdated(updatedParent))
            logger.debug("📈 RemoteChatService.ingestPost\(label): bumped parent \(parentId.uuidString) replyCount → \(updatedParent.replyCount), emitted .postUpdated")
        }
    }

    // MARK: - Sync reads (limited — no remote round-trip)

    func getPost(by id: UUID) -> Post? {
        // Local cache only. The remote-backed equivalent would hit
        // `client.from("posts").select().eq("id", ...)` but the protocol
        // method is synchronous, so we serve from whatever's already loaded.
        posts.first { $0.id == id }
    }

    func getUserVote(for postId: UUID) -> VoteType? {
        userVotes[postId]
    }

    // MARK: - Local-only helpers (parity with mock)

    func injectPost(_ post: Post) {
        // No-op on remote — there's no "inject" semantic against a server.
        // Kept for protocol compatibility with the mock's dev tooling.
    }

    func getLiveGames(for teamIds: Set<UUID>) -> [LiveGame] {
        // Live games are owned by `LiveScoreService`, not the chat backend.
        []
    }

    // MARK: - Async stubs (throw until implemented in follow-up tasks)

    func fetchPosts(forTeamIds teamIds: Set<UUID>?, sortBy: FeedSortOption) async throws -> [Post] {
        throw RemoteChatError.notImplemented("fetchPosts(forTeamIds:sortBy:)")
    }

    /// Resolve a post's author profile from the `users` table and
    /// return the post with `authorUsername` / `authorAvatarEmoji` /
    /// `authorAvatarColorHex` populated. Used by thread VMs so the
    /// parent header always renders the resolved identity even when
    /// the navigated-in Post snapshot was undecorated.
    func resolveAuthor(for post: Post) async -> Post {
        await loadAuthorProfile(for: post.authorId)
        let decorated = decorate(post)
        assertDecorated(decorated, source: "resolveAuthor")
        return decorated
    }

    /// Fetch a single post by id. Used by the in-app notifications
    /// tap path to navigate from a notification row to the relevant
    /// thread. Returns nil if the post no longer exists (e.g.,
    /// deleted between the notification firing and the user tapping
    /// it). Decorates author profile so the resulting Post is safe
    /// to hand to `CasinoThreadView(parentPost:)` which expects a
    /// fully-resolved identity. Vote counts are NOT overlaid here —
    /// the thread VM does its own fresh load and resolves them.
    func fetchPost(id: UUID) async throws -> Post? {
        guard let client else {
            logger.error("❌ RemoteChatService.fetchPost: Supabase client unavailable")
            throw RemoteChatError.notConfigured
        }

        do {
            let rows: [PostRow] = try await client
                .from("posts")
                .select()
                .eq("id", value: id.uuidString)
                .limit(1)
                .execute()
                .value
            guard let row = rows.first else {
                logger.debug("ℹ️ RemoteChatService.fetchPost: \(id.uuidString) not found")
                return nil
            }
            let undecorated = row.toPost()
            await loadAuthorProfile(for: undecorated.authorId)
            let decorated = decorate(undecorated)
            return decorated
        } catch {
            logger.error("❌ RemoteChatService.fetchPost(\(id.uuidString)) failed: \(error)")
            throw RemoteChatError.networkError(error)
        }
    }

    /// Pull every reply for a parent post, sorted oldest-first (chat
    /// thread order). Backed by the `get_post_replies` RPC, which uses
    /// the same active-vote aggregation as `get_room_posts` so reply
    /// vote counts agree with the rest of the iOS vote model.
    func fetchReplies(for postId: UUID) async throws -> [Post] {
        guard let client else {
            logger.error("❌ RemoteChatService.fetchReplies: Supabase client unavailable")
            throw RemoteChatError.notConfigured
        }

        let params = GetPostRepliesParams(parent_post_id_input: postId.uuidString)
        logger.debug("🔵 RemoteChatService.fetchReplies: calling RPC get_post_replies(parent=\(postId.uuidString))")

        do {
            let rows: [RoomPostRow] = try await client
                .rpc("get_post_replies", params: params)
                .execute()
                .value

            let undecorated = rows.map { $0.toPost() }
            await loadAuthorProfiles(for: undecorated.map { $0.authorId })
            let decorated = undecorated.map { decorate($0) }

            // Decoration tripwire — fires `❌ Missing author decoration`
            // only if any reply slipped through without all three
            // identity fields populated.
            for reply in decorated {
                assertDecorated(reply, source: "fetchReplies")
            }

            // Upsert into the local cache so subsequent vote/getPost
            // calls find these reply rows.
            for reply in decorated {
                if let index = posts.firstIndex(where: { $0.id == reply.id }) {
                    posts[index] = reply
                } else {
                    posts.append(reply)
                }
            }
            postsSubject.send(posts)

            await preloadVotes(for: decorated.map { $0.id })

            logger.debug("✅ RemoteChatService.fetchReplies: RPC returned \(decorated.count) reply / replies for parent \(postId.uuidString)")
            return decorated
        } catch {
            logger.error("❌ RemoteChatService.fetchReplies: RPC failed for \(postId.uuidString) — \(error)")
            throw RemoteChatError.networkError(error)
        }
    }

    func fetchReports() async throws -> [Report] {
        throw RemoteChatError.notImplemented("fetchReports()")
    }

    // MARK: - Voting
    //
    // Soft-delete model. The `votes` table keyed on (user_id, post_id) is
    // the source of truth for vote counts; iOS aggregates `is_active=true`
    // rows directly and ignores `posts.upvotes` / `posts.downvotes`.
    //
    //   • vote(on:type:)   → UPSERT (user_id, post_id, room_id, vote_type,
    //                                is_active=true). Re-vote after a
    //                        soft-delete fires a Postgres UPDATE event
    //                        with full old/new payloads, which is what
    //                        other devices need to compute the delta.
    //
    //   • removeVote       → UPDATE is_active=false on the matched row.
    //                        Hard DELETE would lose realtime payload
    //                        fidelity (oldRecord arrives with only the
    //                        primary key) so we never use it.
    //
    // Optimistic local-cache mutation runs synchronously BEFORE the
    // network round-trip via `applyVoteLocally`, so a rapid second tap
    // can't see a stale `userVotes` and double-apply. Network failure
    // reverts the cache.

    func vote(on postId: UUID, type: VoteType) async throws -> Post {
        guard let client else {
            logger.error("❌ RemoteChatService.vote: Supabase client unavailable")
            throw RemoteChatError.notConfigured
        }

        // OPTIMISTIC LOCAL MUTATION FIRST.
        //
        // Why this order matters: the view model decides toggle/swap by
        // reading `service.getUserVote(for:)` (which reads `userVotes`).
        // If `applyVoteLocally` ran AFTER the network round-trip, a
        // rapid second tap during the await would see a stale cache and
        // call `vote(.upvote)` again → two `applyVoteLocally(+1)` calls
        // → local counts off by 2 (the server still upserts to one row
        // via the (user_id, post_id) unique constraint, so it stays at
        // 1; the divergence is purely client-side until next fetch).
        //
        // Applying the cache mutation synchronously before any await
        // closes that window. On network failure the catch block
        // reverts to `priorVote`.
        let priorVote = userVotes[postId]
        let updated = try applyVoteLocally(postId: postId, newVote: type)

        do {
            // The author of a vote also needs a row in `users` (FK).
            try await ensureCurrentUserExists()

            let wire = Self.wireString(for: type)
            // Soft-delete model: every cast vote is is_active=true. A
            // re-vote after a soft-delete upserts onto the existing row
            // (ON CONFLICT user_id,post_id) flipping is_active back to
            // true and updating vote_type — this fires a Postgres UPDATE
            // realtime event with full old/new payloads, which is what
            // other devices need to recompute their counts.
            let payload = VoteUpsert(
                userId: currentUser.id,
                postId: postId,
                roomId: updated.roomId,
                voteType: wire,
                isActive: true
            )

            logger.debug("🔵 RemoteChatService.vote: upserting \(wire) (is_active=true) on post \(postId.uuidString) by user \(self.currentUser.id.uuidString)")

            try await client
                .from("votes")
                .upsert(payload, onConflict: "user_id,post_id")
                .execute()
            logger.debug("✅ RemoteChatService.vote: vote upsert succeeded")

            // Best-effort upvote notification for the post's author.
            // Fires ONLY when:
            //   • type == .upvote — downvotes don't notify.
            //   • priorVote != .upvote — skips the idempotent
            //     re-upvote case (already-upvoted post). The VM
            //     normally short-circuits a same-type re-tap into
            //     removeVote, so this branch typically only fires
            //     for nil→upvote and downvote→upvote transitions.
            //   • removeVote() takes a separate code path (no
            //     notification there at all).
            // Detached so the network call can't delay the vote's
            // success. The AppNotificationService self-skips when
            // post author == voter (voting on your own post), so no
            // explicit check needed at this site.
            if type == .upvote && priorVote != .upvote {
                let recipientUserId = updated.authorId
                let sourceUserId = currentUser.id
                let votedPostId = postId
                let votedRoomId = updated.roomId.uuidString
                let votedPreview = updated.content   // snapshot of
                // the upvoted post for the notification row preview
                // ("NavyBull upvoted: 'No way 💀'").
                Task {
                    do {
                        try await AppNotificationService.shared.createNotification(
                            userId: recipientUserId,
                            type: .upvote,
                            sourceUserId: sourceUserId,
                            postId: votedPostId,
                            roomId: votedRoomId,
                            previewText: votedPreview
                        )
                    } catch {
                        logger.error("⚠️ RemoteChatService.vote: upvote-notification insert failed (non-fatal — vote stayed) — \(error)")
                    }
                }
            }

            return updated
        } catch {
            logger.error("❌ RemoteChatService.vote: vote upsert FAILED — reverting optimistic mutation to prior=\(String(describing: priorVote))")
            logger.debug("    error: \(error)")
            logger.debug("    localized: \(error.localizedDescription)")
            // Revert. If revert itself fails (post somehow gone), swallow —
            // surfacing the network error to the caller is the priority.
            _ = try? applyVoteLocally(postId: postId, newVote: priorVote)
            throw RemoteChatError.networkError(error)
        }
    }

    func removeVote(from postId: UUID) async throws -> Post {
        guard let client else {
            logger.error("❌ RemoteChatService.removeVote: Supabase client unavailable")
            throw RemoteChatError.notConfigured
        }

        // Same optimistic-first ordering as `vote(on:type:)`. See the
        // comment there for the race the order prevents.
        let priorVote = userVotes[postId]
        let updated = try applyVoteLocally(postId: postId, newVote: nil)

        do {
            // SOFT-DELETE: UPDATE is_active=false rather than DELETE.
            // Postgres realtime DELETE oldRecord only carries the primary
            // key (id) even with REPLICA IDENTITY FULL, so other devices
            // can't act on a hard-delete event. Soft-delete via UPDATE
            // delivers full old + new rows to subscribers, allowing the
            // realtime handler to compute the correct -1 delta from
            // (active=true, vote_type=X) → (active=false, vote_type=X).
            logger.debug("🔵 RemoteChatService.removeVote: soft-deleting vote on post \(postId.uuidString) by user \(self.currentUser.id.uuidString) (UPDATE is_active=false)")

            try await client
                .from("votes")
                .update(VoteSoftDeleteUpdate(isActive: false))
                .eq("user_id", value: currentUser.id.uuidString)
                .eq("post_id", value: postId.uuidString)
                .execute()
            logger.debug("✅ RemoteChatService.removeVote: vote soft-delete succeeded")

            return updated
        } catch {
            logger.error("❌ RemoteChatService.removeVote: vote soft-delete FAILED — reverting optimistic mutation to prior=\(String(describing: priorVote))")
            logger.debug("    error: \(error)")
            logger.debug("    localized: \(error.localizedDescription)")
            _ = try? applyVoteLocally(postId: postId, newVote: priorVote)
            throw RemoteChatError.networkError(error)
        }
    }

    /// Mutates the cached `Post`'s upvote/downvote counters to reflect a
    /// change from `userVotes[postId]` → `newVote` (nil = removeVote).
    /// Updates the `userVotes` cache and re-emits `postsSubject`. Returns
    /// the mutated copy.
    private func applyVoteLocally(postId: UUID, newVote: VoteType?) throws -> Post {
        guard let index = posts.firstIndex(where: { $0.id == postId }) else {
            logger.error("❌ RemoteChatService.applyVoteLocally: post \(postId.uuidString) not in local cache")
            throw RemoteChatError.postNotFound
        }

        let prior = userVotes[postId]

        switch (prior, newVote) {
        case (nil, .some(.upvote)):
            posts[index].upvotes += 1
        case (nil, .some(.downvote)):
            posts[index].downvotes += 1
        case (.upvote, .some(.downvote)):
            posts[index].upvotes = max(0, posts[index].upvotes - 1)
            posts[index].downvotes += 1
        case (.downvote, .some(.upvote)):
            posts[index].downvotes = max(0, posts[index].downvotes - 1)
            posts[index].upvotes += 1
        case (.upvote, nil):
            posts[index].upvotes = max(0, posts[index].upvotes - 1)
        case (.downvote, nil):
            posts[index].downvotes = max(0, posts[index].downvotes - 1)
        case (.some(.upvote), .some(.upvote)),
             (.some(.downvote), .some(.downvote)),
             (nil, nil):
            // Idempotent — view model normally wouldn't ask for these.
            break
        }

        userVotes[postId] = newVote
        postsSubject.send(posts)
        return posts[index]
    }

    // MARK: - Vote wire-format mapping

    /// Map a (is_active, vote_type) pair to the (up, down) contribution
    /// that vote makes to a post's counts. Soft-deleted or unknown-type
    /// votes contribute zero. Used by the realtime UPDATE handler to
    /// compute deltas as `newContribution - oldContribution`, which
    /// uniformly handles is_active toggles AND vote_type swaps without
    /// special-casing each transition.
    private static func contribution(active: Bool, voteType: VoteType?) -> (up: Int, down: Int) {
        guard active, let voteType else { return (up: 0, down: 0) }
        switch voteType {
        case .upvote:   return (up: 1, down: 0)
        case .downvote: return (up: 0, down: 1)
        }
    }

    private static func wireString(for type: VoteType) -> String {
        switch type {
        case .upvote:   return "up"
        case .downvote: return "down"
        }
    }

    /// Decode the `votes.vote_type` wire value into a domain `VoteType`.
    /// Production CHECK constraint enforces 'up' / 'down' only — any
    /// other value would have been rejected at insert time, so an
    /// unknown value here is a true error worth surfacing as nil.
    private static func voteType(fromWire string: String) -> VoteType? {
        switch string.lowercased() {
        case "up":   return .upvote
        case "down": return .downvote
        default:     return nil
        }
    }

    func reportPost(_ postId: UUID, reason: ReportReason, additionalInfo: String?) async throws {
        throw RemoteChatError.notImplemented("reportPost(_:reason:additionalInfo:)")
    }

    func blockUser(_ userId: UUID) async throws {
        throw RemoteChatError.notImplemented("blockUser(_:)")
    }

    func unblockUser(_ userId: UUID) async throws {
        throw RemoteChatError.notImplemented("unblockUser(_:)")
    }

    func deletePost(_ postId: UUID) async throws {
        throw RemoteChatError.notImplemented("deletePost(_:)")
    }

    func resolveReport(_ reportId: UUID, resolution: ReportResolution) async throws {
        throw RemoteChatError.notImplemented("resolveReport(_:resolution:)")
    }

    func hidePost(_ postId: UUID) async throws {
        throw RemoteChatError.notImplemented("hidePost(_:)")
    }

    func approvePost(_ postId: UUID) async throws {
        throw RemoteChatError.notImplemented("approvePost(_:)")
    }
}

// MARK: - File-private wire models
//
// Single source of truth for the Supabase REST + realtime payloads this
// service exchanges. UUID-typed throughout — no string-id conversion.

/// Encode shape for the `get_room_posts` RPC params payload. Must use
/// snake_case property names because PostgREST passes the keys to
/// Postgres as the parameter names — a CodingKey mapping wouldn't help
/// since these are wire-format names, not Swift conventions.
///
/// `nonisolated` is required because the project defaults to
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Without it, the
/// synthesized `Encodable` conformance is MainActor-isolated, which
/// conflicts with PostgREST's `rpc(_:params:)` requiring
/// `Encodable & Sendable` cross-actor.
nonisolated private struct GetRoomPostsParams: Encodable, Sendable {
    let room_id_input: String
    let sort_mode: String
}

/// Params for the `get_post_replies(parent_post_id_input)` RPC. Same
/// `nonisolated` rationale as GetRoomPostsParams.
nonisolated private struct GetPostRepliesParams: Encodable, Sendable {
    let parent_post_id_input: String
}

/// Decode shape for the `get_room_posts(room_id_input, sort_mode)` RPC.
/// Mirrors the function's RETURNS TABLE (...) declaration in
/// `supabase_migration_get_room_posts_rpc.sql`. Active vote counts come
/// back per row, so callers don't need a separate fetchVoteCounts hop.
private struct RoomPostRow: Decodable {
    let id: UUID
    let userId: UUID
    let content: String
    let roomId: UUID
    let roomType: String
    let teamId: UUID?
    let parentId: UUID?
    let replyCount: Int?
    let reportCount: Int?
    let isHidden: Bool?
    let createdAt: Date
    let activeUpvotes: Int?
    let activeDownvotes: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case content
        case roomId = "room_id"
        case roomType = "room_type"
        case teamId = "team_id"
        case parentId = "parent_id"
        case replyCount = "reply_count"
        case reportCount = "report_count"
        case isHidden = "is_hidden"
        case createdAt = "created_at"
        case activeUpvotes = "active_upvotes"
        case activeDownvotes = "active_downvotes"
        // `score` and `hot_score` are also returned by the RPC but iOS
        // doesn't decode them — Post.score is computed client-side from
        // upvotes/downvotes, and hot_score is only used for server-side
        // ordering. Decoding them would just be dead bytes.
    }

    func toPost() -> Post {
        Post(
            id: id,
            authorId: userId,
            content: content,
            createdAt: createdAt,
            upvotes: activeUpvotes ?? 0,
            downvotes: activeDownvotes ?? 0,
            replyCount: replyCount ?? 0,
            parentId: parentId,
            gameId: nil,
            teamId: teamId,
            roomId: roomId,
            roomType: roomType,
            isHidden: isHidden ?? false,
            reportCount: reportCount ?? 0
        )
    }
}

/// Minimal decode of a votes-table change event. `room_id` is read so
/// the listener can defensively verify the server-side filter held.
/// `vote_type` is now consulted by the delta-apply path so each event
/// directly mutates the cached post's up/down counters without needing
/// to round-trip the votes table.
private struct VoteEventRow: Decodable {
    let postId: UUID
    let userId: UUID
    let roomId: UUID
    let voteType: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
        case userId = "user_id"
        case roomId = "room_id"
        case voteType = "vote_type"
        case isActive = "is_active"
    }
}

/// Tolerant fallback decoder for DELETE oldRecord payloads when the strict
/// `VoteEventRow` decode fails — every field is optional so a partial
/// payload (e.g. REPLICA IDENTITY DEFAULT delivering only the primary key,
/// RLS hiding a column, schema drift) still gives the listener something
/// to act on. Used only by `handleVoteDelete`'s fallback path; INSERT and
/// UPDATE keep the strict decode because they're not affected by the
/// REPLICA IDENTITY setting.
private struct VoteEventPartial: Decodable {
    let postId: UUID?
    let userId: UUID?
    let roomId: UUID?
    let voteType: String?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case postId = "post_id"
        case userId = "user_id"
        case roomId = "room_id"
        case voteType = "vote_type"
        case isActive = "is_active"
    }
}

private struct VoteUpsert: Encodable {
    let userId: UUID
    let postId: UUID
    let roomId: UUID
    let voteType: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case postId = "post_id"
        case roomId = "room_id"
        case voteType = "vote_type"
        case isActive = "is_active"
    }
}

/// Payload for soft-delete (removeVote). UPDATEs only the is_active
/// column on a row matched by (user_id, post_id), preserving the
/// original vote_type so realtime UPDATE oldRecord still carries it.
private struct VoteSoftDeleteUpdate: Encodable {
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case isActive = "is_active"
    }
}

private struct VoteRow: Decodable {
    let userId: UUID
    let postId: UUID
    let voteType: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case postId = "post_id"
        case voteType = "vote_type"
        case isActive = "is_active"
    }
}

// MARK: - Author profile types
//
// In-memory snapshot of a row from the `users` table for use as a chat
// author identity. Cached by `RemoteChatService.authorProfiles`.

private struct AuthorProfile: Equatable {
    let id: UUID
    let username: String
    let avatarEmoji: String
    let avatarColorHex: String
}

/// Wire format for the SELECT against `users` when resolving authors.
/// Only the columns the UI cares about are decoded.
private struct UserRow: Decodable {
    let id: UUID
    let username: String
    let avatarEmoji: String
    let avatarColor: String

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case avatarEmoji = "avatar_emoji"
        case avatarColor = "avatar_color"
    }
}

private struct UserUpsert: Encodable {
    let id: UUID
    let username: String
    let avatarEmoji: String
    let avatarColor: String

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case avatarEmoji = "avatar_emoji"
        case avatarColor = "avatar_color"
    }
}

private struct PostInsert: Encodable {
    let userId: UUID
    let content: String
    let roomId: UUID
    let roomType: String
    let teamId: UUID?
    let parentId: UUID?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case content
        case roomId = "room_id"
        case roomType = "room_type"
        case teamId = "team_id"
        case parentId = "parent_id"
    }
}

private struct PostRow: Decodable {
    // Required fields — a row missing any of these is malformed.
    let id: UUID
    let userId: UUID
    let content: String
    let createdAt: Date

    // Room scope. After STAGE 2 of the migration these are NOT NULL on the
    // server, but we decode optional + default to tolerate any pre-stage-2
    // rows that slipped through.
    let roomId: UUID?
    let roomType: String?

    // Optional FK / threading fields — semantically nullable in the schema.
    let teamId: UUID?
    let parentId: UUID?

    // Reply/moderation counters — optional so rows from a schema that
    // hasn't added these columns yet still decode; defaulted in `toPost()`.
    //
    // NOTE: `posts.upvotes` and `posts.downvotes` are deliberately NOT
    // decoded here. Vote totals are derived from the `votes` table (active
    // rows only) and overlaid by `fetchPostsForRoom`. The server-side
    // counters are cache/analytics and have proven unreliable in practice.
    let replyCount: Int?
    let reportCount: Int?
    let isHidden: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case content
        case roomId = "room_id"
        case roomType = "room_type"
        case teamId = "team_id"
        case parentId = "parent_id"
        case replyCount = "reply_count"
        case reportCount = "report_count"
        case isHidden = "is_hidden"
        case createdAt = "created_at"
    }

    /// Map the wire row to the iOS domain `Post`. Missing optional columns
    /// are filled with safe defaults. If `room_id` is absent (legacy row
    /// pre-migration), fall back to the team-room derivation so the post
    /// still routes correctly through the in-app filters.
    ///
    /// `upvotes` / `downvotes` are seeded to 0 — the caller is responsible
    /// for overlaying the correct counts from `fetchVoteCounts`. The only
    /// path that doesn't overlay is `handlePostInserted` (a brand-new post
    /// from realtime), where 0/0 is the correct initial state anyway.
    func toPost() -> Post {
        let resolvedRoomId: UUID = {
            if let roomId = roomId { return roomId }
            if let teamId = teamId { return ChatRoom.team(teamId).roomId }
            return UUID()  // unreachable after STAGE 2; placeholder for malformed rows
        }()
        let resolvedRoomType = roomType ?? "team"

        return Post(
            id: id,
            authorId: userId,
            content: content,
            createdAt: createdAt,
            upvotes: 0,
            downvotes: 0,
            replyCount: replyCount ?? 0,
            parentId: parentId,
            gameId: nil,
            teamId: teamId,
            roomId: resolvedRoomId,
            roomType: resolvedRoomType,
            isHidden: isHidden ?? false,
            reportCount: reportCount ?? 0
        )
    }
}

// MARK: - Errors

enum RemoteChatError: LocalizedError {
    case notConfigured
    case invalidContent(String)
    case postCreationFailed
    case postNotFound
    case networkError(Error)
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase client is not configured. Check SupabaseConfig and Supabase.xcconfig."
        case .invalidContent(let message):
            return message
        case .postCreationFailed:
            return "The server accepted the post but did not return it."
        case .postNotFound:
            return "Post not found in local cache. Fetch posts before voting."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .notImplemented(let symbol):
            return "RemoteChatService.\(symbol) is not implemented yet."
        }
    }
}
