import Foundation

// MARK: - Sports namespace
//
// Canonical Swift models for Phase 5's real sports schema. These mirror
// the `public.games` and `public.game_rooms` tables created by
// `supabase_migration_games_and_game_rooms.sql` field-for-field.
//
// Why nested under `enum Sports`?
//   The legacy LIVE page already ships top-level `Game` (Models.swift)
//   and `GameStatus` (Models.swift) types, plus `LiveGame` /
//   `LiveGameStatus` in `ChatService.swift` and `UpcomingGame` in
//   `LiveGamesViewModel.swift` — all currently driving mock-data flow.
//   Wrapping the new canonical models in a `Sports` namespace keeps
//   them addressable as `Sports.Game` / `Sports.GameStatus` / etc.,
//   avoids every existing collision, and lets the legacy types stay in
//   place until the LIVE page is rewired to read from Supabase.
//
// Why caseless `enum` (not `struct`/`class`/`namespace`)?
//   Swift idiom for type-only namespaces — uninstantiable by
//   construction, no runtime cost, no init clutter.
enum Sports {

    // MARK: Game
    //
    // One row in `public.games` — a real scheduled game instance keyed
    // off the upstream provider's game id. CodingKeys map each Swift
    // property to its snake_case Supabase column.
    struct Game: Codable, Identifiable, Equatable {
        let id: UUID
        let provider: String
        let providerGameId: String
        let league: String
        let season: String?
        let homeTeamId: UUID
        let awayTeamId: UUID
        let startTime: Date
        let status: GameStatus
        let period: String?
        let clock: String?
        let homeScore: Int
        let awayScore: Int
        let lastSyncedAt: Date?
        let finalAt: Date?
        let createdAt: Date
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case provider
            case providerGameId  = "provider_game_id"
            case league
            case season
            case homeTeamId      = "home_team_id"
            case awayTeamId      = "away_team_id"
            case startTime       = "start_time"
            case status
            case period
            case clock
            case homeScore       = "home_score"
            case awayScore       = "away_score"
            case lastSyncedAt    = "last_synced_at"
            case finalAt         = "final_at"
            case createdAt       = "created_at"
            case updatedAt       = "updated_at"
        }
    }

    // MARK: GameStatus
    //
    // Mirrors the `games_status_check` CHECK constraint exactly.
    // String raw values match the Supabase TEXT column verbatim, so
    // Codable round-trips without a custom decoder.
    enum GameStatus: String, Codable, Equatable, CaseIterable {
        case scheduled
        case pregame
        case live
        case halftime
        case final
        case closed
        case postponed
        case cancelled
    }

    // MARK: GameRoom
    //
    // One row in `public.game_rooms` — 1:1 with a `Sports.Game`.
    // Carries the chat-room identifier (`roomId`) that
    // `posts.room_id` will eventually reference, plus lifecycle
    // timestamps that drive the room's open/close transitions.
    struct GameRoom: Codable, Identifiable, Equatable {
        let id: UUID
        let gameId: UUID
        let roomId: UUID
        let status: GameRoomStatus
        let opensAt: Date
        let closesAt: Date?
        let createdAt: Date
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case gameId    = "game_id"
            case roomId    = "room_id"
            case status
            case opensAt   = "opens_at"
            case closesAt  = "closes_at"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
        }
    }

    // MARK: GameRoomStatus
    //
    // Mirrors the `game_rooms_status_check` CHECK constraint exactly.
    enum GameRoomStatus: String, Codable, Equatable, CaseIterable {
        case pending
        case open
        case live
        case final
        case closed
        case archived
    }
}
