import Foundation
import CryptoKit

// MARK: - Wire format (JUMBO backend → iOS)
//
// This shape is OWNED by the JUMBO backend. Upstream providers (ESPN, SportsDataIO,
// API-Sports, etc.) get normalized into this format on the server. The iOS app
// must never know which upstream is in use.

struct LiveGameAPIResponse: Decodable {
    let games: [LiveGameDTO]
}

struct LiveGameDTO: Decodable {
    /// Stable, provider-agnostic identifier (e.g. "nfl-401547439"). Backend
    /// guarantees this value is the same across polls for a given game.
    let id: String

    /// "NFL" | "NBA" | "MLB" | "NHL" — matches `League.rawValue`.
    let league: String

    /// "scheduled" | "live" | "halftime" | "final"
    let status: String

    /// Team identifier from our internal taxonomy (e.g. "BUF"). Matches
    /// `SportsTeam.shortName` for the team's league.
    let homeTeamId: String
    let awayTeamId: String

    let homeScore: Int
    let awayScore: Int

    /// Display string for the period: "Q1", "1st Quarter", "Top 7th", etc.
    let period: String?

    /// Display string for time left in period: "4:23", "" when N/A.
    let timeRemaining: String?

    /// Optional ISO-8601 timestamps (currently unused on iOS, kept for future).
    let startTime: String?
    let lastUpdated: String?
}

// MARK: - Mapping to internal LiveGame
//
// Mapping fails silently (returns nil) when:
//   - the league string is unknown
//   - either team id can't be resolved against TeamDatabase
//   - the status string is unknown
// This is the right policy for V1: a single bad row from upstream should not
// poison the whole list. The remaining games still render.

extension LiveGameDTO {
    func toLiveGame() -> LiveGame? {
        guard let league = League(rawValue: league) else { return nil }
        guard let home = TeamDatabase.team(byShortName: homeTeamId, league: league) else { return nil }
        guard let away = TeamDatabase.team(byShortName: awayTeamId, league: league) else { return nil }
        guard let mappedStatus = LiveGameStatus.fromAPI(status) else { return nil }

        return LiveGame(
            id: deterministicUUID(from: id),
            homeTeam: home,
            awayTeam: away,
            homeScore: homeScore,
            awayScore: awayScore,
            status: mappedStatus,
            period: period ?? "",
            timeRemaining: timeRemaining ?? ""
        )
    }
}

extension LiveGameAPIResponse {
    func toLiveGames() -> [LiveGame] {
        games.compactMap { $0.toLiveGame() }
    }
}

private extension LiveGameStatus {
    static func fromAPI(_ raw: String) -> LiveGameStatus? {
        switch raw.lowercased() {
        case "scheduled", "pre", "pregame": return .scheduled
        case "live", "in_progress", "in progress": return .live
        case "halftime", "half": return .halftime
        case "final", "ended", "post", "complete", "completed": return .final_
        default: return nil
        }
    }
}

// MARK: - Deterministic UUID
//
// Backend ids are arbitrary strings ("nfl-401547439"); the iOS LiveGame model
// uses UUID. We derive a v5-style UUID by SHA-256-hashing the id and packing
// the first 16 bytes — same input always yields the same UUID, so SwiftUI
// list diffing and our notifiedGameIds set remain stable across polls.

private func deterministicUUID(from string: String) -> UUID {
    let digest = SHA256.hash(data: Data(string.utf8))
    var bytes = Array(digest.prefix(16))
    // Set version (5) and variant (RFC 4122) bits so the value is a well-formed UUID.
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}
