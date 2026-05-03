import Foundation

// MARK: - AppNotification
//
// In-app notification record (replies, upvotes for now). Named
// `AppNotification` to avoid colliding with Foundation's `Notification`
// and Apple's `UserNotifications` types.
//
// Mirrors the `notifications` table created by
// supabase_migration_notifications_table.sql:
//
//   id              uuid     primary key
//   user_id         uuid     recipient (auth.users)
//   type            text     'reply' | 'upvote'
//   source_user_id  uuid     actor (nullable on user-deleted)
//   post_id         uuid     subject post (no FK in schema)
//   room_id         text     chat room id (TEXT, not UUID — see
//                            migration comment)
//   created_at      timestamptz
//   read            bool

enum AppNotificationType: String, Codable, CaseIterable {
    case reply
    case upvote
}

struct AppNotification: Identifiable, Codable, Equatable {
    let id: UUID
    let userId: UUID
    let type: AppNotificationType
    let sourceUserId: UUID?
    /// For reply notifications: the PARENT post (so tap opens its
    /// thread). For upvote notifications: the upvoted post itself.
    /// May be nil only for legacy rows pre-hooks.
    let postId: UUID?
    let roomId: String?
    /// Snapshot of the relevant post content at creation time.
    ///   • reply  → the reply's content
    ///   • upvote → the upvoted post's content
    /// Optional because (a) historical rows pre-migration may be
    /// nil and (b) the column is plain TEXT with no NOT NULL.
    let previewText: String?
    let createdAt: Date
    let read: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case type
        case sourceUserId = "source_user_id"
        case postId = "post_id"
        case roomId = "room_id"
        case previewText = "preview_text"
        case createdAt = "created_at"
        case read
    }
}
