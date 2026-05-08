import Foundation
import OSLog
import Supabase

private let logger = Logger(subsystem: "com.jumbo", category: "sports")

// MARK: - SportsGameService
//
// Supabase-backed READ API for the canonical Phase-5 sports schema:
//   • public.games       → Sports.Game
//   • public.game_rooms  → Sports.GameRoom
//
// Scope of THIS file (intentionally narrow — read API only):
//   • fetchLiveGames()                — games currently in progress / pregame / halftime
//   • fetchUpcomingGames(limit:)      — scheduled games starting now or later
//   • fetchGameRoom(forGameId:)       — the room belonging to a specific game
//   • fetchGameRoom(byRoomId:)        — reverse lookup: room → row
//
// Out of scope (deliberately not implemented yet):
//   • Writes (insert/upsert) — the ingest worker owns those.
//   • Realtime subscriptions on public.games — a follow-up will publish
//     the table and add a channel filtered by status=eq.live so iOS
//     gets score deltas without polling.
//   • Wiring into LiveGamesViewModel / LiveGamesView. Existing mock
//     flow (LiveScoreService + MockLiveScoreProvider) is untouched.
//   • ChatRoom rewrite. Posts still flow through the team-pair-keyed
//     ChatRoom.game(home, away) until the LIVE page is rewired.
//
// Style mirrors AppNotificationService:
//   @MainActor singleton, lazy SupabaseClient accessor that returns nil
//   when unconfigured, structured Logger, do/try with debug + error
//   logging on every call, dedicated error enum.

@MainActor
final class SportsGameService {

    static let shared = SportsGameService()

    private var client: SupabaseClient? {
        SupabaseClientProvider.shared.client
    }

    private init() {}

    // MARK: - Errors

    enum SportsGameError: Error {
        /// SupabaseClientProvider returned nil — Supabase.xcconfig is
        /// missing or malformed. Same shape as AppNotificationError so
        /// callers can pattern-match consistently.
        case notConfigured

        /// Underlying network/decoding failure from the SDK. The
        /// inner error is retained for diagnostics.
        case networkError(Error)
    }

    // MARK: - Read: Games

    /// Returns games whose status indicates they are visible in the
    /// LIVE NOW band. Includes `pregame`, `live`, and `halftime` —
    /// all three present a "happening now" UX (pregame is the
    /// ~15-minute pre-tip-off window, halftime is mid-game
    /// intermission, live is in-progress play).
    ///
    /// Sort: `start_time` ascending so earliest kickoffs lead the
    /// list — matches the visual rhythm of the existing LIVE NOW
    /// section.
    func fetchLiveGames() async throws -> [Sports.Game] {
        guard let client else {
            logger.error("❌ SportsGameService.fetchLiveGames: Supabase client unavailable")
            throw SportsGameError.notConfigured
        }

        let liveStatuses: [String] = [
            Sports.GameStatus.pregame.rawValue,
            Sports.GameStatus.live.rawValue,
            Sports.GameStatus.halftime.rawValue,
        ]

        logger.debug("🔵 SportsGameService.fetchLiveGames: statuses=\(liveStatuses, privacy: .public)")

        do {
            let rows: [Sports.Game] = try await client
                .from("games")
                .select()
                .in("status", values: liveStatuses)
                .order("start_time", ascending: true)
                .execute()
                .value
            logger.debug("✅ SportsGameService.fetchLiveGames: returned \(rows.count) row(s)")
            return rows
        } catch {
            logger.error("❌ SportsGameService.fetchLiveGames: FAILED — \(error)")
            throw SportsGameError.networkError(error)
        }
    }

    /// Returns scheduled games with kickoff at or after the current
    /// moment, oldest-first, capped at `limit`. Default `limit: 50`
    /// matches the AppNotificationService convention.
    ///
    /// Filter: `status = scheduled` AND `start_time >= now()`. Games
    /// already past kickoff are excluded even if their status hasn't
    /// flipped yet — keeps COMING UP from showing fixtures that
    /// should already be in LIVE NOW.
    func fetchUpcomingGames(limit: Int = 50) async throws -> [Sports.Game] {
        guard let client else {
            logger.error("❌ SportsGameService.fetchUpcomingGames: Supabase client unavailable")
            throw SportsGameError.notConfigured
        }

        // PostgREST filter operands must be strings. Use a single
        // shared ISO8601 formatter so we don't pay the build cost on
        // every call. Includes fractional seconds because Supabase
        // TIMESTAMPTZ comparisons accept the same precision the SDK
        // emits when encoding Dates.
        let nowIso = Self.iso8601.string(from: Date())

        logger.debug("🔵 SportsGameService.fetchUpcomingGames: limit=\(limit) since=\(nowIso, privacy: .public)")

        do {
            let rows: [Sports.Game] = try await client
                .from("games")
                .select()
                .eq("status", value: Sports.GameStatus.scheduled.rawValue)
                .gte("start_time", value: nowIso)
                .order("start_time", ascending: true)
                .limit(limit)
                .execute()
                .value
            logger.debug("✅ SportsGameService.fetchUpcomingGames: returned \(rows.count) row(s)")
            return rows
        } catch {
            logger.error("❌ SportsGameService.fetchUpcomingGames: FAILED — \(error)")
            throw SportsGameError.networkError(error)
        }
    }

    // MARK: - Read: Game rooms

    /// Returns the chat room associated with a specific game, or `nil`
    /// if no room row exists yet (e.g., the lifecycle worker hasn't
    /// run for that game).
    ///
    /// Note: `public.game_rooms` enforces `UNIQUE(game_id)`, so this
    /// call returns at most one row. We still fetch into an array and
    /// take `.first` rather than calling `.single()` — `.single()`
    /// throws on zero rows, which we want to distinguish from a real
    /// error.
    func fetchGameRoom(forGameId gameId: UUID) async throws -> Sports.GameRoom? {
        guard let client else {
            logger.error("❌ SportsGameService.fetchGameRoom(forGameId:): Supabase client unavailable")
            throw SportsGameError.notConfigured
        }

        logger.debug("🔵 SportsGameService.fetchGameRoom(forGameId:): game=\(gameId.uuidString)")

        do {
            let rows: [Sports.GameRoom] = try await client
                .from("game_rooms")
                .select()
                .eq("game_id", value: gameId.uuidString)
                .limit(1)
                .execute()
                .value
            let room = rows.first
            logger.debug("✅ SportsGameService.fetchGameRoom(forGameId:): \(room == nil ? "miss" : "hit")")
            return room
        } catch {
            logger.error("❌ SportsGameService.fetchGameRoom(forGameId:): FAILED — \(error)")
            throw SportsGameError.networkError(error)
        }
    }

    /// Reverse lookup: given a `room_id` (the chat-room UUID
    /// referenced by `posts.room_id`), return the `Sports.GameRoom`
    /// row, or `nil` if no row exists. Used when we need to resolve a
    /// post's room back to its game (e.g., notifications, deep
    /// links).
    ///
    /// `public.game_rooms` enforces `UNIQUE(room_id)`, so this is
    /// also at-most-one. Same array-then-first treatment as
    /// `fetchGameRoom(forGameId:)`.
    func fetchGameRoom(byRoomId roomId: UUID) async throws -> Sports.GameRoom? {
        guard let client else {
            logger.error("❌ SportsGameService.fetchGameRoom(byRoomId:): Supabase client unavailable")
            throw SportsGameError.notConfigured
        }

        logger.debug("🔵 SportsGameService.fetchGameRoom(byRoomId:): room=\(roomId.uuidString)")

        do {
            let rows: [Sports.GameRoom] = try await client
                .from("game_rooms")
                .select()
                .eq("room_id", value: roomId.uuidString)
                .limit(1)
                .execute()
                .value
            let room = rows.first
            logger.debug("✅ SportsGameService.fetchGameRoom(byRoomId:): \(room == nil ? "miss" : "hit")")
            return room
        } catch {
            logger.error("❌ SportsGameService.fetchGameRoom(byRoomId:): FAILED — \(error)")
            throw SportsGameError.networkError(error)
        }
    }

    // MARK: - Helpers

    /// Shared ISO 8601 formatter used to encode date filter operands.
    /// Static + lazy so the cost is paid once per process. Includes
    /// fractional seconds — Postgres TIMESTAMPTZ comparisons handle
    /// the higher precision fine, and matches the SDK's default
    /// outbound Date encoding.
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
