import Foundation
import CryptoKit

// MARK: - ChatRoom
//
// Identity of a single chat room. Each case maps to a stable canonical key
// string; that key feeds a deterministic UUID derivation so the same room
// always has the same `room_id` server-side AND on every device.
//
// The Postgres `deterministic_room_uuid(text)` function in
// `supabase_migration_room_scoped_posts.sql` mirrors this derivation byte-
// for-byte. The keys MUST match, including case — UUIDs are lowercased
// because Postgres `uuid::text` is lowercase.

enum ChatRoom: Equatable, Hashable {
    case team(UUID)
    case game(homeTeamId: UUID, awayTeamId: UUID)
    case trending(UUID)
    /// Game room whose `room_id` comes pre-resolved from the
    /// `public.game_rooms` table — one room per scheduled game
    /// instance, not per team pair. Carries the UUID directly; the
    /// `roomId` accessor returns it as-is rather than running it
    /// through the SHA-256 derivation used for the legacy cases.
    /// Wire-compatible with the legacy `.game` case (same
    /// `roomType: "game"`, same nil `metadataTeamId`) so posts
    /// scoping / subscriptions / RLS work without further changes.
    case canonicalGame(roomId: UUID)

    // MARK: - Canonical key

    /// String fed into the deterministic UUID hash. Must match the SQL
    /// helper byte-for-byte. UUIDs are lowercased.
    var canonicalKey: String {
        switch self {
        case .team(let id):
            return "team:\(id.uuidString.lowercased())"

        case .game(let home, let away):
            // Sorted so [home,away] and [away,home] produce the same key.
            let pair = [home.uuidString.lowercased(),
                        away.uuidString.lowercased()].sorted()
            return "game:\(pair[0]):\(pair[1])"

        case .trending(let id):
            return "trending:\(id.uuidString.lowercased())"

        case .canonicalGame(let roomId):
            // Not actually used for hashing (the `roomId` accessor
            // bypasses the SHA-256 path for this case), but keep a
            // sensible string here for logging / debugging and to
            // avoid colliding with any team-pair `.game` key (which
            // contains TWO uuids, never one).
            return "canonicalGame:\(roomId.uuidString.lowercased())"
        }
    }

    // MARK: - Deterministic room id

    /// Stable UUID derived from `canonicalKey`. Same input → same UUID,
    /// every machine, every launch. Mirrors `SportsTeam.stableID` and
    /// the SQL `deterministic_room_uuid` function.
    ///
    /// Exception: `.canonicalGame(roomId:)` returns its stored UUID
    /// directly. The room id for canonical games is owned by
    /// `public.game_rooms.room_id` and assigned by the ingest /
    /// lifecycle worker — no client-side derivation involved.
    var roomId: UUID {
        if case .canonicalGame(let id) = self {
            return id
        }
        let digest = SHA256.hash(data: Data(canonicalKey.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Server-side discriminator

    /// One of `"team"`, `"game"`, `"trending"`. Stored alongside `room_id`
    /// in the `posts.room_type` column for analytics / RLS / debugging.
    /// Canonical game rooms emit `"game"` (same value as the legacy
    /// `.game` case) so existing posts schema and RLS checks need no
    /// changes — the discriminator stays uniform across both game-room
    /// flavors.
    var roomType: String {
        switch self {
        case .team:                     return "team"
        case .game, .canonicalGame:     return "game"
        case .trending:                 return "trending"
        }
    }

    // MARK: - Optional team_id metadata

    /// Carried into `posts.team_id` as descriptive metadata only — NOT used
    /// for scoping. Only `.team` rooms have a canonical single-team
    /// association. Game rooms intentionally emit nil (no semantic answer
    /// for "which side is this post about"); trending rooms have no team
    /// relationship.
    var metadataTeamId: UUID? {
        switch self {
        case .team(let id):                          return id
        case .game, .trending, .canonicalGame:       return nil
        }
    }
}
