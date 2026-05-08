import Foundation

// MARK: - SportsGameAdapter
//
// Pure value-mapping helpers that convert Phase-5 canonical
// `Sports.Game` rows (mirroring `public.games` in Supabase) into the
// legacy UI-facing models the existing LIVE page renders today
// (`LiveGame`, `UpcomingGame`, `LiveGameStatus`). Lives in its own
// type so:
//
//   • the conversion contract is testable / inspectable in isolation;
//   • neither `LiveGamesViewModel` nor `Sports` has to import the
//     other's implementation;
//   • the eventual UI rewrite that consumes `Sports.Game` directly
//     can drop this adapter without touching any other layer.
//
// Caseless `enum` to make the type uninstantiable — these are pure
// static utilities, no state, no init.
//
// All three helpers are intentionally NIL-on-miss:
//   • If a team UUID isn't present in the bundled `TeamDatabase`,
//     `liveGame(from:)` and `upcomingGame(from:)` return `nil` so the
//     caller can skip the row and log it. (Happens when Supabase ever
//     references a team the iOS bundle doesn't yet know about.)
//   • If `Sports.Game.league` doesn't decode into a `League` rawValue,
//     `upcomingGame(from:)` returns `nil` for the same reason.
enum SportsGameAdapter {

    // MARK: Live game

    /// Returns a `LiveGame` whose `homeTeam` / `awayTeam` are looked
    /// up in `TeamDatabase` (the bundled iOS team list). The returned
    /// game's id, scores, period, and clock all come straight from
    /// the canonical row; status is mapped via `liveStatus(_:)`
    /// below to collapse 8 canonical states into the 4-case legacy
    /// enum the UI already understands.
    ///
    /// Uses `TeamDatabase.team(byCanonicalId:)`, which consults both
    /// the iOS-authoritative (uppercase-league) UUID index and the
    /// Supabase-canonical (lowercase-league) UUID index — see the
    /// long comment in `TeamData.swift`. Returns `nil` only when a
    /// canonical row references a team neither index knows about
    /// (a real data gap, not a derivation mismatch).
    static func liveGame(from game: Sports.Game) -> LiveGame? {
        guard let home = TeamDatabase.team(byCanonicalId: game.homeTeamId),
              let away = TeamDatabase.team(byCanonicalId: game.awayTeamId) else {
            return nil
        }
        return LiveGame(
            id: game.id,
            homeTeam: home,
            awayTeam: away,
            homeScore: game.homeScore,
            awayScore: game.awayScore,
            status: liveStatus(game.status),
            period: game.period ?? "",
            timeRemaining: game.clock ?? ""
        )
    }

    // MARK: Upcoming game

    /// Returns an `UpcomingGame`, or `nil` if either team UUID can't
    /// be resolved (via `team(byCanonicalId:)` — see liveGame above)
    /// or if the canonical row's `league: String` doesn't match a
    /// `League` rawValue.
    ///
    /// `Sports.Game.league` is lowercase ("nfl"/"nba"/"mlb"/"nhl")
    /// per the migration's `teams_league_check` constraint, but
    /// `League.rawValue` is uppercase. Uppercase the input before
    /// the lookup so canonical rows resolve.
    static func upcomingGame(from game: Sports.Game) -> UpcomingGame? {
        guard let home = TeamDatabase.team(byCanonicalId: game.homeTeamId),
              let away = TeamDatabase.team(byCanonicalId: game.awayTeamId),
              let league = League(rawValue: game.league.uppercased()) else {
            return nil
        }
        return UpcomingGame(
            id: game.id,
            homeTeam: home,
            awayTeam: away,
            startTime: game.startTime,
            league: league
        )
    }

    // MARK: Status mapping

    /// `Sports.GameStatus` (8 cases) → legacy `LiveGameStatus`
    /// (4 cases). The mapping rationale:
    ///
    ///   • `.live`           → `.live`
    ///   • `.halftime`       → `.halftime`
    ///   • `.pregame`        → `.live`        (collapses into the
    ///     same UI band so a "kicking off in 12 min" pre-tip-off
    ///     game renders identically to an in-progress game on
    ///     LIVE NOW)
    ///   • `.final, .closed` → `.final_`      (game over)
    ///   • `.scheduled, .postponed, .cancelled`
    ///                       → `.scheduled`   (none of these should
    ///     reach this path because `SportsGameService.fetchLiveGames`
    ///     filters them out; covered defensively)
    static func liveStatus(_ status: Sports.GameStatus) -> LiveGameStatus {
        switch status {
        case .live:                              return .live
        case .halftime:                          return .halftime
        case .pregame:                           return .live
        case .scheduled, .postponed, .cancelled: return .scheduled
        case .final, .closed:                    return .final_
        }
    }
}
