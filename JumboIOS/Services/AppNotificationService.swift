import Foundation
import Combine
import OSLog
import Supabase

private let logger = Logger(subsystem: "com.jumbo", category: "notifications")

// MARK: - AppNotificationService
//
// Supabase-backed write API for the in-app notifications feed (replies,
// upvotes for now). Named `AppNotificationService` to avoid colliding
// with the existing `NotificationService` (which wraps Apple's
// `UNUserNotificationCenter` for push/local notifications — different
// domain).
//
// Scope of THIS file (intentionally narrow — read API, realtime sub,
// mark-as-read, unread count, UI badge are out of scope until follow-
// up tasks):
//   • createNotification(userId:type:sourceUserId:postId:roomId:) —
//     INSERT into the `notifications` table.
//
// Behavior:
//   • Self-notifications are silently skipped (userId == sourceUserId)
//     so a user voting on / replying to their own post doesn't
//     generate a notification for themselves. Mirrors the RLS check
//     `WITH CHECK (auth.uid() <> user_id)` so we fail fast client-side
//     instead of round-tripping for an inevitable RLS denial.
//   • Wire column names exactly match the SQL schema (snake_case via
//     CodingKeys on `NotificationInsert`).

@MainActor
final class AppNotificationService {
    static let shared = AppNotificationService()

    private var client: SupabaseClient? {
        SupabaseClientProvider.shared.client
    }

    // MARK: - Realtime arrivals
    //
    // Single long-lived Postgres realtime channel filtered server-side
    // by `user_id=eq.<currentUser>`. Each INSERT event is decoded and
    // republished via `arrivalsPublisher` so multiple consumers can
    // listen with no redundant subscriptions:
    //   • UnreadNotificationsBadge — bumps count instantly on any tab
    //   • NotificationsViewModel — prepends to its list while Alerts
    //     is open (subscribes via cancellables, cleans up on dealloc)
    //
    // The subscription is started lazily on the first call to
    // `startRealtimeSubscription(for:)`. Idempotent — re-calling for
    // the same userId is a no-op; calling for a different userId
    // tears down and re-opens the channel.

    private let arrivalsSubject = PassthroughSubject<AppNotification, Never>()
    var arrivalsPublisher: AnyPublisher<AppNotification, Never> {
        arrivalsSubject.eraseToAnyPublisher()
    }

    private var realtimeChannel: RealtimeChannelV2?
    private var realtimeListenerTask: Task<Void, Never>?
    private var subscribedUserId: UUID?

    /// Decoder for realtime payloads. Doesn't share with the
    /// `Codable` synthesis on `AppNotification` because the SDK's
    /// default decoder applies `convertFromSnakeCase` which would
    /// conflict with the model's explicit CodingKeys.
    private static let realtimeDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            // Try ISO8601 with fractional, then without; then no-zone
            // microsecond/millisecond formats — Supabase realtime can
            // emit any of these depending on column type.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
                        "yyyy-MM-dd'T'HH:mm:ss.SSS",
                        "yyyy-MM-dd'T'HH:mm:ss"] {
                f.dateFormat = fmt
                if let d = f.date(from: s) { return d }
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode date string \(s)"
            )
        }
        return decoder
    }()

    private init() {}

    /// Insert a new notification row. No-op when `userId == sourceUserId`
    /// (self-notification suppression). Throws on Supabase / network
    /// failure or RLS denial.
    ///
    /// Caller contract:
    ///   • `userId`         — recipient. Must be a `public.users.id`
    ///                        (FK enforced by the schema). Self-
    ///                        notifications are skipped automatically.
    ///   • `sourceUserId`   — actor (the user whose action triggered
    ///                        this notification). Must also be a
    ///                        `public.users.id`.
    ///   • `postId`         — the chat post the notification is about
    ///                        (the parent for replies, the target for
    ///                        upvotes). Use `Post.id`.
    ///   • `roomId`         — the room identifier stored on the post
    ///                        (`Post.roomId.uuidString`). Note
    ///                        `notifications.room_id` is TEXT in the
    ///                        schema even though `posts.room_id` is UUID
    ///                        — `.uuidString` at the call site.
    ///
    /// Type assumptions:
    ///   • `userId`, `sourceUserId`, `postId` are UUID-typed because
    ///     the underlying columns are UUID. The user's spec wrote
    ///     `String` for these but the rest of the iOS codebase passes
    ///     UUIDs around (e.g., `RemoteChatService.vote(on postId: UUID)`)
    ///     so taking UUID here keeps callers consistent.
    ///   • `roomId` is `String` because the `notifications.room_id`
    ///     column is TEXT, not UUID — see the bullet above.
    func createNotification(
        userId: UUID,
        type: AppNotificationType,
        sourceUserId: UUID,
        postId: UUID,
        roomId: String,
        previewText: String? = nil
    ) async throws {
        // Self-notification guard.
        guard userId != sourceUserId else {
            logger.debug("ℹ️ AppNotificationService.createNotification: SKIPPED — self-notification (user_id == source_user_id == \(userId.uuidString))")
            return
        }

        guard let client else {
            logger.error("❌ AppNotificationService.createNotification: Supabase client unavailable")
            throw AppNotificationError.notConfigured
        }

        let payload = NotificationInsert(
            userId: userId,
            type: type.rawValue,
            sourceUserId: sourceUserId,
            postId: postId,
            roomId: roomId,
            previewText: previewText
        )

        let previewSummary = previewText.map { "\"\($0.prefix(40))\"" } ?? "<nil>"
        logger.debug("🔵 AppNotificationService.createNotification: inserting type=\(type.rawValue) recipient=\(userId.uuidString) source=\(sourceUserId.uuidString) post=\(postId.uuidString) room=\(roomId) preview=\(previewSummary)")

        do {
            try await client
                .from("notifications")
                .insert(payload)
                .execute()
            logger.debug("✅ AppNotificationService.createNotification: insert succeeded")
        } catch {
            logger.error("❌ AppNotificationService.createNotification: insert FAILED — \(error)")
            throw AppNotificationError.networkError(error)
        }
    }

    // MARK: - Read API

    /// Fetch the most recent notifications for a user, newest first.
    /// `limit` caps the result size (default 50). Returns an empty
    /// array when the user has no notifications.
    func fetchNotifications(userId: UUID, limit: Int = 50) async throws -> [AppNotification] {
        guard let client else {
            logger.error("❌ AppNotificationService.fetchNotifications: Supabase client unavailable")
            throw AppNotificationError.notConfigured
        }

        logger.debug("🔵 AppNotificationService.fetchNotifications: user=\(userId.uuidString) limit=\(limit)")

        do {
            let rows: [AppNotification] = try await client
                .from("notifications")
                .select()
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .limit(limit)
                .execute()
                .value
            logger.debug("✅ AppNotificationService.fetchNotifications: returned \(rows.count) row(s)")
            return rows
        } catch {
            logger.error("❌ AppNotificationService.fetchNotifications: FAILED — \(error)")
            throw AppNotificationError.networkError(error)
        }
    }

    /// Fetch the count of unread notifications for a user.
    /// Uses the PostgREST count-only path (`head: true, count: .exact`)
    /// so the request body is empty — only a Content-Range header
    /// carrying the count comes back. The PostgrestResponse exposes
    /// it as `response.count`. Returns 0 when there are no rows or
    /// (defensively) when count is somehow nil.
    func fetchUnreadCount(userId: UUID) async throws -> Int {
        guard let client else {
            logger.error("❌ AppNotificationService.fetchUnreadCount: Supabase client unavailable")
            throw AppNotificationError.notConfigured
        }

        logger.debug("🔵 AppNotificationService.fetchUnreadCount: user=\(userId.uuidString)")

        do {
            let response = try await client
                .from("notifications")
                .select("*", head: true, count: .exact)
                .eq("user_id", value: userId.uuidString)
                .eq("read", value: "false")
                .execute()
            let count = response.count ?? 0
            logger.debug("✅ AppNotificationService.fetchUnreadCount: \(count) unread")
            return count
        } catch {
            logger.error("❌ AppNotificationService.fetchUnreadCount: FAILED — \(error)")
            throw AppNotificationError.networkError(error)
        }
    }

    /// Mark every unread notification for a user as read in one
    /// round-trip. The `read = false` filter is included so the
    /// update only touches rows that need changing — saves a write
    /// when the inbox is already cleared.
    func markAllAsRead(userId: UUID) async throws {
        guard let client else {
            logger.error("❌ AppNotificationService.markAllAsRead: Supabase client unavailable")
            throw AppNotificationError.notConfigured
        }

        logger.debug("🔵 AppNotificationService.markAllAsRead: user=\(userId.uuidString)")

        do {
            try await client
                .from("notifications")
                .update(NotificationReadUpdate())
                .eq("user_id", value: userId.uuidString)
                .eq("read", value: "false")
                .execute()
            logger.debug("✅ AppNotificationService.markAllAsRead: succeeded")
        } catch {
            logger.error("❌ AppNotificationService.markAllAsRead: FAILED — \(error)")
            throw AppNotificationError.networkError(error)
        }
    }

    // MARK: - Realtime control

    /// Start (or replace) the realtime INSERT subscription for the
    /// given user id. Server-side filter `user_id=eq.<uuid>` ensures
    /// only this user's notifications fan out to `arrivalsPublisher`.
    /// Idempotent — same id is a no-op; different id tears down the
    /// previous channel first.
    func startRealtimeSubscription(for userId: UUID) async {
        if subscribedUserId == userId, realtimeChannel != nil {
            logger.debug("ℹ️ AppNotificationService.startRealtimeSubscription: already subscribed to \(userId.uuidString)")
            return
        }
        await stopRealtimeSubscription()

        guard let client else {
            logger.error("❌ AppNotificationService.startRealtimeSubscription: Supabase client unavailable")
            return
        }

        let channel = client.realtimeV2.channel("notifications:\(userId.uuidString)")
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "notifications",
            filter: "user_id=eq.\(userId.uuidString)"
        )

        await channel.subscribe()
        logger.debug("✅ AppNotificationService.startRealtimeSubscription: channel subscribed for \(userId.uuidString)")

        let task = Task { [weak self] in
            for await action in inserts {
                guard let self else { return }
                await self.handleRealtimeInsert(action)
            }
            logger.debug("🟡 AppNotificationService.realtime listener exited")
        }

        realtimeChannel = channel
        realtimeListenerTask = task
        subscribedUserId = userId
    }

    /// Tear down any active realtime subscription. Called rarely
    /// (logout / userId switch). The shared singleton normally keeps
    /// the channel open for the app's lifetime once started.
    func stopRealtimeSubscription() async {
        realtimeListenerTask?.cancel()
        realtimeListenerTask = nil
        if let channel = realtimeChannel, let client {
            await client.realtimeV2.removeChannel(channel)
        }
        realtimeChannel = nil
        subscribedUserId = nil
    }

    private func handleRealtimeInsert(_ action: InsertAction) async {
        // The class is @MainActor, so this method (and the
        // subsequent send) is guaranteed to run on the main actor.
        // Subscribers using `.receive(on: DispatchQueue.main)` will
        // therefore deliver synchronously on the main thread with
        // no extra hop.
        do {
            let notification = try action.decodeRecord(
                as: AppNotification.self,
                decoder: Self.realtimeDecoder
            )
            logger.debug("📨 AppNotificationService.realtime: ARRIVAL id=\(notification.id.uuidString) type=\(notification.type.rawValue) recipient=\(notification.userId.uuidString) source=\(notification.sourceUserId?.uuidString ?? "<nil>") read=\(notification.read)")
            arrivalsSubject.send(notification)
            logger.debug("📤 AppNotificationService.realtime: PUBLISHED to arrivalsSubject (subscribers will receive on main)")
        } catch {
            logger.error("❌ AppNotificationService.realtime: decode failed — \(error)")
            logger.debug("    raw record was: \(action.record)")
        }
    }

    // MARK: - Batch user profile fetch

    /// Resolve the display profiles for a set of source-user ids in
    /// ONE query against `public.users`. Used by NotificationsViewModel
    /// after `fetchNotifications` to populate row username + avatar
    /// without N+1. Empty input → empty result. Missing rows simply
    /// don't appear in the returned dict — caller falls back to a
    /// "Someone" placeholder.
    func fetchUserProfiles(ids: [UUID]) async throws -> [UUID: AppUserProfile] {
        guard let client, !ids.isEmpty else { return [:] }

        // Dedupe first — a notification batch often has the same
        // source user repeated across rows.
        let unique = Array(Set(ids))
        logger.debug("🔵 AppNotificationService.fetchUserProfiles: \(unique.count) unique id(s)")

        do {
            let rows: [UserProfileRow] = try await client
                .from("users")
                .select("id, username, avatar_emoji, avatar_color")
                .in("id", values: unique.map { $0.uuidString })
                .execute()
                .value

            let dict = Dictionary(uniqueKeysWithValues: rows.map { row in
                (row.id, AppUserProfile(
                    id: row.id,
                    username: row.username,
                    avatarEmoji: row.avatarEmoji,
                    avatarColor: row.avatarColor
                ))
            })
            logger.debug("✅ AppNotificationService.fetchUserProfiles: resolved \(dict.count)/\(unique.count)")
            return dict
        } catch {
            logger.error("❌ AppNotificationService.fetchUserProfiles: FAILED — \(error)")
            throw AppNotificationError.networkError(error)
        }
    }

    /// Mark a single notification as read. The `user_id` filter is
    /// belt-and-suspenders alongside the `id` filter — guarantees a
    /// caller that holds someone else's notification id can't flip
    /// its read state to true. Once auth is wired and the RLS update
    /// policy keys on `auth.uid() = user_id`, this becomes redundant
    /// at the server but is kept here for client-side intent clarity.
    func markAsRead(notificationId: UUID, userId: UUID) async throws {
        guard let client else {
            logger.error("❌ AppNotificationService.markAsRead: Supabase client unavailable")
            throw AppNotificationError.notConfigured
        }

        logger.debug("🔵 AppNotificationService.markAsRead: id=\(notificationId.uuidString) user=\(userId.uuidString)")

        do {
            try await client
                .from("notifications")
                .update(NotificationReadUpdate())
                .eq("id", value: notificationId.uuidString)
                .eq("user_id", value: userId.uuidString)
                .execute()
            logger.debug("✅ AppNotificationService.markAsRead: succeeded")
        } catch {
            logger.error("❌ AppNotificationService.markAsRead: FAILED — \(error)")
            throw AppNotificationError.networkError(error)
        }
    }
}

// MARK: - File-private wire model
//
// Encodable payload for the insert. Column names match the schema
// exactly via CodingKeys. `id`, `created_at`, and `read` are omitted
// so the database defaults (`gen_random_uuid()`, `NOW()`, `FALSE`)
// take effect.

/// Public profile snapshot returned by `fetchUserProfiles(ids:)`.
/// Lightweight — only the fields the notifications row needs to
/// render the source user's name and avatar. Optional avatar
/// fields are nil when the underlying `public.users` row has them
/// blank (older accounts pre-deterministic-backfill). Callers
/// fall back to `Post.deterministicAvatarEmoji(for:)` etc. for
/// blanks so cross-device renders stay consistent.
struct AppUserProfile: Equatable {
    let id: UUID
    let username: String
    let avatarEmoji: String?
    let avatarColor: String?
}

/// Decoder for the `select id, username, avatar_emoji, avatar_color`
/// path in `fetchUserProfiles`.
private struct UserProfileRow: Decodable {
    let id: UUID
    let username: String
    let avatarEmoji: String?
    let avatarColor: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case avatarEmoji = "avatar_emoji"
        case avatarColor = "avatar_color"
    }
}

/// Encodable payload for the `mark-as-read` UPDATE. Fixed body —
/// always sets `read = true`. Filtered server-side by `user_id`
/// (and `id` for the single-row variant).
private struct NotificationReadUpdate: Encodable {
    let read: Bool = true
}

private struct NotificationInsert: Encodable {
    let userId: UUID
    let type: String
    let sourceUserId: UUID
    let postId: UUID
    let roomId: String
    let previewText: String?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case type
        case sourceUserId = "source_user_id"
        case postId = "post_id"
        case roomId = "room_id"
        case previewText = "preview_text"
    }
}

// MARK: - Errors

enum AppNotificationError: LocalizedError {
    case notConfigured
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase client is not configured."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}
