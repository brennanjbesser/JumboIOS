import Foundation
import SwiftUI
import CryptoKit

// MARK: - League Enum
enum League: String, CaseIterable, Codable, Identifiable {
    case nfl = "NFL"
    case nba = "NBA"
    case mlb = "MLB"
    case nhl = "NHL"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .nfl: return "football.fill"
        case .nba: return "basketball.fill"
        case .mlb: return "baseball.fill"
        case .nhl: return "hockey.puck.fill"
        }
    }

    var displayName: String { rawValue }
}

// MARK: - Team Model
struct SportsTeam: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let name: String
    let shortName: String
    let city: String
    let league: League
    let primaryColorHex: String
    let secondaryColorHex: String
    let logoEmoji: String // Using emoji as placeholder for team logos

    var fullName: String { "\(city) \(name)" }

    var primaryColor: Color { Color(hex: primaryColorHex) }
    var secondaryColor: Color { Color(hex: secondaryColorHex) }

    init(name: String, shortName: String, city: String, league: League, primaryColorHex: String, secondaryColorHex: String, logoEmoji: String) {
        // The id is DERIVED from (league, shortName) — never random. This
        // means the same team produces the same UUID on every app launch and
        // on every machine, so a `team_id` written to Supabase today is
        // findable tomorrow. See `SportsTeam.stableID(league:shortName:)`.
        self.id = SportsTeam.stableID(league: league, shortName: shortName)
        self.name = name
        self.shortName = shortName
        self.city = city
        self.league = league
        self.primaryColorHex = primaryColorHex
        self.secondaryColorHex = secondaryColorHex
        self.logoEmoji = logoEmoji
    }

    // MARK: - Stable id derivation
    //
    // SportsTeam.id MUST be stable across app restarts so persisted data
    // (Supabase posts, UserPreferences.followedTeamIds, etc.) keeps
    // resolving to the same team. We derive the UUID by SHA-256-hashing
    // the canonical key `"<league>_<shortName>"` (e.g. "NBA_CHI" for the
    // Chicago Bulls) and packing the first 16 bytes into a UUID with the
    // version (5) and variant (RFC 4122) bits set. Same input → same UUID,
    // forever.
    //
    // Mirror the pattern from `LiveGameAPIResponse.swift`'s deterministic
    // UUID helper. Kept inline (rather than extracted to a shared util)
    // to keep the change scoped to this file; can be lifted out later.

    static func stableID(league: League, shortName: String) -> UUID {
        let key = "\(league.rawValue)_\(shortName)"
        let digest = SHA256.hash(data: Data(key.utf8))
        var bytes = Array(digest.prefix(16))
        // Set version (5 = name-based SHA-1, used here for v5-shape) and
        // RFC 4122 variant bits so the value is a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - All Teams Data
struct TeamDatabase {
    // MARK: - NFL Teams
    static let nflTeams: [SportsTeam] = [
        // AFC East
        SportsTeam(name: "Bills", shortName: "BUF", city: "Buffalo", league: .nfl, primaryColorHex: "#00338D", secondaryColorHex: "#C60C30", logoEmoji: "🦬"),
        SportsTeam(name: "Dolphins", shortName: "MIA", city: "Miami", league: .nfl, primaryColorHex: "#008E97", secondaryColorHex: "#FC4C02", logoEmoji: "🐬"),
        SportsTeam(name: "Patriots", shortName: "NE", city: "New England", league: .nfl, primaryColorHex: "#002244", secondaryColorHex: "#C60C30", logoEmoji: "🇺🇸"),
        SportsTeam(name: "Jets", shortName: "NYJ", city: "New York", league: .nfl, primaryColorHex: "#125740", secondaryColorHex: "#FFFFFF", logoEmoji: "✈️"),
        // AFC North
        SportsTeam(name: "Ravens", shortName: "BAL", city: "Baltimore", league: .nfl, primaryColorHex: "#241773", secondaryColorHex: "#9E7C0C", logoEmoji: "🐦‍⬛"),
        SportsTeam(name: "Bengals", shortName: "CIN", city: "Cincinnati", league: .nfl, primaryColorHex: "#FB4F14", secondaryColorHex: "#000000", logoEmoji: "🐅"),
        SportsTeam(name: "Browns", shortName: "CLE", city: "Cleveland", league: .nfl, primaryColorHex: "#311D00", secondaryColorHex: "#FF3C00", logoEmoji: "🟤"),
        SportsTeam(name: "Steelers", shortName: "PIT", city: "Pittsburgh", league: .nfl, primaryColorHex: "#FFB612", secondaryColorHex: "#101820", logoEmoji: "⚙️"),
        // AFC South
        SportsTeam(name: "Texans", shortName: "HOU", city: "Houston", league: .nfl, primaryColorHex: "#03202F", secondaryColorHex: "#A71930", logoEmoji: "🤠"),
        SportsTeam(name: "Colts", shortName: "IND", city: "Indianapolis", league: .nfl, primaryColorHex: "#002C5F", secondaryColorHex: "#A2AAAD", logoEmoji: "🐴"),
        SportsTeam(name: "Jaguars", shortName: "JAX", city: "Jacksonville", league: .nfl, primaryColorHex: "#006778", secondaryColorHex: "#D7A22A", logoEmoji: "🐆"),
        SportsTeam(name: "Titans", shortName: "TEN", city: "Tennessee", league: .nfl, primaryColorHex: "#0C2340", secondaryColorHex: "#4B92DB", logoEmoji: "⚔️"),
        // AFC West
        SportsTeam(name: "Broncos", shortName: "DEN", city: "Denver", league: .nfl, primaryColorHex: "#FB4F14", secondaryColorHex: "#002244", logoEmoji: "🐎"),
        SportsTeam(name: "Chiefs", shortName: "KC", city: "Kansas City", league: .nfl, primaryColorHex: "#E31837", secondaryColorHex: "#FFB81C", logoEmoji: "🪶"),
        SportsTeam(name: "Raiders", shortName: "LV", city: "Las Vegas", league: .nfl, primaryColorHex: "#000000", secondaryColorHex: "#A5ACAF", logoEmoji: "☠️"),
        SportsTeam(name: "Chargers", shortName: "LAC", city: "Los Angeles", league: .nfl, primaryColorHex: "#0080C6", secondaryColorHex: "#FFC20E", logoEmoji: "⚡"),
        // NFC East
        SportsTeam(name: "Cowboys", shortName: "DAL", city: "Dallas", league: .nfl, primaryColorHex: "#003594", secondaryColorHex: "#869397", logoEmoji: "⭐"),
        SportsTeam(name: "Giants", shortName: "NYG", city: "New York", league: .nfl, primaryColorHex: "#0B2265", secondaryColorHex: "#A71930", logoEmoji: "🗽"),
        SportsTeam(name: "Eagles", shortName: "PHI", city: "Philadelphia", league: .nfl, primaryColorHex: "#004C54", secondaryColorHex: "#A5ACAF", logoEmoji: "🦅"),
        SportsTeam(name: "Commanders", shortName: "WAS", city: "Washington", league: .nfl, primaryColorHex: "#5A1414", secondaryColorHex: "#FFB612", logoEmoji: "🎖️"),
        // NFC North
        SportsTeam(name: "Bears", shortName: "CHI", city: "Chicago", league: .nfl, primaryColorHex: "#0B162A", secondaryColorHex: "#C83803", logoEmoji: "🐻"),
        SportsTeam(name: "Lions", shortName: "DET", city: "Detroit", league: .nfl, primaryColorHex: "#0076B6", secondaryColorHex: "#B0B7BC", logoEmoji: "🦁"),
        SportsTeam(name: "Packers", shortName: "GB", city: "Green Bay", league: .nfl, primaryColorHex: "#203731", secondaryColorHex: "#FFB612", logoEmoji: "🧀"),
        SportsTeam(name: "Vikings", shortName: "MIN", city: "Minnesota", league: .nfl, primaryColorHex: "#4F2683", secondaryColorHex: "#FFC62F", logoEmoji: "⛵"),
        // NFC South
        SportsTeam(name: "Falcons", shortName: "ATL", city: "Atlanta", league: .nfl, primaryColorHex: "#A71930", secondaryColorHex: "#000000", logoEmoji: "🦅"),
        SportsTeam(name: "Panthers", shortName: "CAR", city: "Carolina", league: .nfl, primaryColorHex: "#0085CA", secondaryColorHex: "#101820", logoEmoji: "🐆"),
        SportsTeam(name: "Saints", shortName: "NO", city: "New Orleans", league: .nfl, primaryColorHex: "#D3BC8D", secondaryColorHex: "#101820", logoEmoji: "⚜️"),
        SportsTeam(name: "Buccaneers", shortName: "TB", city: "Tampa Bay", league: .nfl, primaryColorHex: "#D50A0A", secondaryColorHex: "#34302B", logoEmoji: "🏴‍☠️"),
        // NFC West
        SportsTeam(name: "Cardinals", shortName: "ARI", city: "Arizona", league: .nfl, primaryColorHex: "#97233F", secondaryColorHex: "#000000", logoEmoji: "🐦"),
        SportsTeam(name: "Rams", shortName: "LAR", city: "Los Angeles", league: .nfl, primaryColorHex: "#003594", secondaryColorHex: "#FFA300", logoEmoji: "🐏"),
        SportsTeam(name: "49ers", shortName: "SF", city: "San Francisco", league: .nfl, primaryColorHex: "#AA0000", secondaryColorHex: "#B3995D", logoEmoji: "⛏️"),
        SportsTeam(name: "Seahawks", shortName: "SEA", city: "Seattle", league: .nfl, primaryColorHex: "#002244", secondaryColorHex: "#69BE28", logoEmoji: "🦅"),
    ]

    // MARK: - NBA Teams
    static let nbaTeams: [SportsTeam] = [
        // Atlantic
        SportsTeam(name: "Celtics", shortName: "BOS", city: "Boston", league: .nba, primaryColorHex: "#007A33", secondaryColorHex: "#BA9653", logoEmoji: "☘️"),
        SportsTeam(name: "Nets", shortName: "BKN", city: "Brooklyn", league: .nba, primaryColorHex: "#000000", secondaryColorHex: "#FFFFFF", logoEmoji: "🏀"),
        SportsTeam(name: "Knicks", shortName: "NYK", city: "New York", league: .nba, primaryColorHex: "#006BB6", secondaryColorHex: "#F58426", logoEmoji: "🗽"),
        SportsTeam(name: "76ers", shortName: "PHI", city: "Philadelphia", league: .nba, primaryColorHex: "#006BB6", secondaryColorHex: "#ED174C", logoEmoji: "🔔"),
        SportsTeam(name: "Raptors", shortName: "TOR", city: "Toronto", league: .nba, primaryColorHex: "#CE1141", secondaryColorHex: "#000000", logoEmoji: "🦖"),
        // Central
        SportsTeam(name: "Bulls", shortName: "CHI", city: "Chicago", league: .nba, primaryColorHex: "#CE1141", secondaryColorHex: "#000000", logoEmoji: "🐂"),
        SportsTeam(name: "Cavaliers", shortName: "CLE", city: "Cleveland", league: .nba, primaryColorHex: "#860038", secondaryColorHex: "#FDBB30", logoEmoji: "⚔️"),
        SportsTeam(name: "Pistons", shortName: "DET", city: "Detroit", league: .nba, primaryColorHex: "#C8102E", secondaryColorHex: "#1D42BA", logoEmoji: "🔧"),
        SportsTeam(name: "Pacers", shortName: "IND", city: "Indiana", league: .nba, primaryColorHex: "#002D62", secondaryColorHex: "#FDBB30", logoEmoji: "🏎️"),
        SportsTeam(name: "Bucks", shortName: "MIL", city: "Milwaukee", league: .nba, primaryColorHex: "#00471B", secondaryColorHex: "#EEE1C6", logoEmoji: "🦌"),
        // Southeast
        SportsTeam(name: "Hawks", shortName: "ATL", city: "Atlanta", league: .nba, primaryColorHex: "#E03A3E", secondaryColorHex: "#C1D32F", logoEmoji: "🦅"),
        SportsTeam(name: "Hornets", shortName: "CHA", city: "Charlotte", league: .nba, primaryColorHex: "#1D1160", secondaryColorHex: "#00788C", logoEmoji: "🐝"),
        SportsTeam(name: "Heat", shortName: "MIA", city: "Miami", league: .nba, primaryColorHex: "#98002E", secondaryColorHex: "#F9A01B", logoEmoji: "🔥"),
        SportsTeam(name: "Magic", shortName: "ORL", city: "Orlando", league: .nba, primaryColorHex: "#0077C0", secondaryColorHex: "#C4CED4", logoEmoji: "✨"),
        SportsTeam(name: "Wizards", shortName: "WAS", city: "Washington", league: .nba, primaryColorHex: "#002B5C", secondaryColorHex: "#E31837", logoEmoji: "🧙"),
        // Northwest
        SportsTeam(name: "Nuggets", shortName: "DEN", city: "Denver", league: .nba, primaryColorHex: "#0E2240", secondaryColorHex: "#FEC524", logoEmoji: "⛏️"),
        SportsTeam(name: "Timberwolves", shortName: "MIN", city: "Minnesota", league: .nba, primaryColorHex: "#0C2340", secondaryColorHex: "#236192", logoEmoji: "🐺"),
        SportsTeam(name: "Thunder", shortName: "OKC", city: "Oklahoma City", league: .nba, primaryColorHex: "#007AC1", secondaryColorHex: "#EF3B24", logoEmoji: "⛈️"),
        SportsTeam(name: "Trail Blazers", shortName: "POR", city: "Portland", league: .nba, primaryColorHex: "#E03A3E", secondaryColorHex: "#000000", logoEmoji: "🌲"),
        SportsTeam(name: "Jazz", shortName: "UTA", city: "Utah", league: .nba, primaryColorHex: "#002B5C", secondaryColorHex: "#00471B", logoEmoji: "🎵"),
        // Pacific
        SportsTeam(name: "Warriors", shortName: "GSW", city: "Golden State", league: .nba, primaryColorHex: "#1D428A", secondaryColorHex: "#FFC72C", logoEmoji: "🌉"),
        SportsTeam(name: "Clippers", shortName: "LAC", city: "Los Angeles", league: .nba, primaryColorHex: "#C8102E", secondaryColorHex: "#1D428A", logoEmoji: "⛵"),
        SportsTeam(name: "Lakers", shortName: "LAL", city: "Los Angeles", league: .nba, primaryColorHex: "#552583", secondaryColorHex: "#FDB927", logoEmoji: "💜"),
        SportsTeam(name: "Suns", shortName: "PHX", city: "Phoenix", league: .nba, primaryColorHex: "#1D1160", secondaryColorHex: "#E56020", logoEmoji: "☀️"),
        SportsTeam(name: "Kings", shortName: "SAC", city: "Sacramento", league: .nba, primaryColorHex: "#5A2D81", secondaryColorHex: "#63727A", logoEmoji: "👑"),
        // Southwest
        SportsTeam(name: "Mavericks", shortName: "DAL", city: "Dallas", league: .nba, primaryColorHex: "#00538C", secondaryColorHex: "#002B5E", logoEmoji: "🐴"),
        SportsTeam(name: "Rockets", shortName: "HOU", city: "Houston", league: .nba, primaryColorHex: "#CE1141", secondaryColorHex: "#000000", logoEmoji: "🚀"),
        SportsTeam(name: "Grizzlies", shortName: "MEM", city: "Memphis", league: .nba, primaryColorHex: "#5D76A9", secondaryColorHex: "#12173F", logoEmoji: "🐻"),
        SportsTeam(name: "Pelicans", shortName: "NOP", city: "New Orleans", league: .nba, primaryColorHex: "#0C2340", secondaryColorHex: "#C8102E", logoEmoji: "🦤"),
        SportsTeam(name: "Spurs", shortName: "SAS", city: "San Antonio", league: .nba, primaryColorHex: "#C4CED4", secondaryColorHex: "#000000", logoEmoji: "🤠"),
    ]

    // MARK: - MLB Teams
    static let mlbTeams: [SportsTeam] = [
        // AL East
        SportsTeam(name: "Orioles", shortName: "BAL", city: "Baltimore", league: .mlb, primaryColorHex: "#DF4601", secondaryColorHex: "#000000", logoEmoji: "🐦"),
        SportsTeam(name: "Red Sox", shortName: "BOS", city: "Boston", league: .mlb, primaryColorHex: "#BD3039", secondaryColorHex: "#0C2340", logoEmoji: "🧦"),
        SportsTeam(name: "Yankees", shortName: "NYY", city: "New York", league: .mlb, primaryColorHex: "#003087", secondaryColorHex: "#E4002C", logoEmoji: "⚾"),
        SportsTeam(name: "Rays", shortName: "TB", city: "Tampa Bay", league: .mlb, primaryColorHex: "#092C5C", secondaryColorHex: "#8FBCE6", logoEmoji: "☀️"),
        SportsTeam(name: "Blue Jays", shortName: "TOR", city: "Toronto", league: .mlb, primaryColorHex: "#134A8E", secondaryColorHex: "#E8291C", logoEmoji: "🐦"),
        // AL Central
        SportsTeam(name: "White Sox", shortName: "CWS", city: "Chicago", league: .mlb, primaryColorHex: "#27251F", secondaryColorHex: "#C4CED4", logoEmoji: "🧦"),
        SportsTeam(name: "Guardians", shortName: "CLE", city: "Cleveland", league: .mlb, primaryColorHex: "#00385D", secondaryColorHex: "#E50022", logoEmoji: "🛡️"),
        SportsTeam(name: "Tigers", shortName: "DET", city: "Detroit", league: .mlb, primaryColorHex: "#0C2340", secondaryColorHex: "#FA4616", logoEmoji: "🐅"),
        SportsTeam(name: "Royals", shortName: "KC", city: "Kansas City", league: .mlb, primaryColorHex: "#004687", secondaryColorHex: "#BD9B60", logoEmoji: "👑"),
        SportsTeam(name: "Twins", shortName: "MIN", city: "Minnesota", league: .mlb, primaryColorHex: "#002B5C", secondaryColorHex: "#D31145", logoEmoji: "👯"),
        // AL West
        SportsTeam(name: "Astros", shortName: "HOU", city: "Houston", league: .mlb, primaryColorHex: "#002D62", secondaryColorHex: "#EB6E1F", logoEmoji: "⭐"),
        SportsTeam(name: "Angels", shortName: "LAA", city: "Los Angeles", league: .mlb, primaryColorHex: "#BA0021", secondaryColorHex: "#003263", logoEmoji: "😇"),
        SportsTeam(name: "Athletics", shortName: "OAK", city: "Oakland", league: .mlb, primaryColorHex: "#003831", secondaryColorHex: "#EFB21E", logoEmoji: "🐘"),
        SportsTeam(name: "Mariners", shortName: "SEA", city: "Seattle", league: .mlb, primaryColorHex: "#0C2C56", secondaryColorHex: "#005C5C", logoEmoji: "⚓"),
        SportsTeam(name: "Rangers", shortName: "TEX", city: "Texas", league: .mlb, primaryColorHex: "#003278", secondaryColorHex: "#C0111F", logoEmoji: "🤠"),
        // NL East
        SportsTeam(name: "Braves", shortName: "ATL", city: "Atlanta", league: .mlb, primaryColorHex: "#CE1141", secondaryColorHex: "#13274F", logoEmoji: "🪓"),
        SportsTeam(name: "Marlins", shortName: "MIA", city: "Miami", league: .mlb, primaryColorHex: "#00A3E0", secondaryColorHex: "#EF3340", logoEmoji: "🐟"),
        SportsTeam(name: "Mets", shortName: "NYM", city: "New York", league: .mlb, primaryColorHex: "#002D72", secondaryColorHex: "#FF5910", logoEmoji: "🗽"),
        SportsTeam(name: "Phillies", shortName: "PHI", city: "Philadelphia", league: .mlb, primaryColorHex: "#E81828", secondaryColorHex: "#002D72", logoEmoji: "🔔"),
        SportsTeam(name: "Nationals", shortName: "WAS", city: "Washington", league: .mlb, primaryColorHex: "#AB0003", secondaryColorHex: "#14225A", logoEmoji: "🇺🇸"),
        // NL Central
        SportsTeam(name: "Cubs", shortName: "CHC", city: "Chicago", league: .mlb, primaryColorHex: "#0E3386", secondaryColorHex: "#CC3433", logoEmoji: "🐻"),
        SportsTeam(name: "Reds", shortName: "CIN", city: "Cincinnati", league: .mlb, primaryColorHex: "#C6011F", secondaryColorHex: "#000000", logoEmoji: "🔴"),
        SportsTeam(name: "Brewers", shortName: "MIL", city: "Milwaukee", league: .mlb, primaryColorHex: "#12284B", secondaryColorHex: "#B6922E", logoEmoji: "🍺"),
        SportsTeam(name: "Pirates", shortName: "PIT", city: "Pittsburgh", league: .mlb, primaryColorHex: "#27251F", secondaryColorHex: "#FDB827", logoEmoji: "🏴‍☠️"),
        SportsTeam(name: "Cardinals", shortName: "STL", city: "St. Louis", league: .mlb, primaryColorHex: "#C41E3A", secondaryColorHex: "#0C2340", logoEmoji: "🐦"),
        // NL West
        SportsTeam(name: "Diamondbacks", shortName: "ARI", city: "Arizona", league: .mlb, primaryColorHex: "#A71930", secondaryColorHex: "#E3D4AD", logoEmoji: "🐍"),
        SportsTeam(name: "Rockies", shortName: "COL", city: "Colorado", league: .mlb, primaryColorHex: "#33006F", secondaryColorHex: "#C4CED4", logoEmoji: "🏔️"),
        SportsTeam(name: "Dodgers", shortName: "LAD", city: "Los Angeles", league: .mlb, primaryColorHex: "#005A9C", secondaryColorHex: "#EF3E42", logoEmoji: "⚾"),
        SportsTeam(name: "Padres", shortName: "SD", city: "San Diego", league: .mlb, primaryColorHex: "#2F241D", secondaryColorHex: "#FFC425", logoEmoji: "⛪"),
        SportsTeam(name: "Giants", shortName: "SF", city: "San Francisco", league: .mlb, primaryColorHex: "#FD5A1E", secondaryColorHex: "#27251F", logoEmoji: "🌉"),
    ]

    // MARK: - NHL Teams
    static let nhlTeams: [SportsTeam] = [
        // Atlantic
        SportsTeam(name: "Bruins", shortName: "BOS", city: "Boston", league: .nhl, primaryColorHex: "#FFB81C", secondaryColorHex: "#000000", logoEmoji: "🐻"),
        SportsTeam(name: "Sabres", shortName: "BUF", city: "Buffalo", league: .nhl, primaryColorHex: "#002654", secondaryColorHex: "#FCB514", logoEmoji: "⚔️"),
        SportsTeam(name: "Red Wings", shortName: "DET", city: "Detroit", league: .nhl, primaryColorHex: "#CE1126", secondaryColorHex: "#FFFFFF", logoEmoji: "🐙"),
        SportsTeam(name: "Panthers", shortName: "FLA", city: "Florida", league: .nhl, primaryColorHex: "#041E42", secondaryColorHex: "#C8102E", logoEmoji: "🐆"),
        SportsTeam(name: "Canadiens", shortName: "MTL", city: "Montreal", league: .nhl, primaryColorHex: "#AF1E2D", secondaryColorHex: "#192168", logoEmoji: "🍁"),
        SportsTeam(name: "Senators", shortName: "OTT", city: "Ottawa", league: .nhl, primaryColorHex: "#C52032", secondaryColorHex: "#C2912C", logoEmoji: "🏛️"),
        SportsTeam(name: "Lightning", shortName: "TB", city: "Tampa Bay", league: .nhl, primaryColorHex: "#002868", secondaryColorHex: "#FFFFFF", logoEmoji: "⚡"),
        SportsTeam(name: "Maple Leafs", shortName: "TOR", city: "Toronto", league: .nhl, primaryColorHex: "#00205B", secondaryColorHex: "#FFFFFF", logoEmoji: "🍁"),
        // Metropolitan
        SportsTeam(name: "Hurricanes", shortName: "CAR", city: "Carolina", league: .nhl, primaryColorHex: "#CC0000", secondaryColorHex: "#000000", logoEmoji: "🌀"),
        SportsTeam(name: "Blue Jackets", shortName: "CBJ", city: "Columbus", league: .nhl, primaryColorHex: "#002654", secondaryColorHex: "#CE1126", logoEmoji: "⭐"),
        SportsTeam(name: "Devils", shortName: "NJ", city: "New Jersey", league: .nhl, primaryColorHex: "#CE1126", secondaryColorHex: "#000000", logoEmoji: "😈"),
        SportsTeam(name: "Islanders", shortName: "NYI", city: "New York", league: .nhl, primaryColorHex: "#00539B", secondaryColorHex: "#F47D30", logoEmoji: "🏝️"),
        SportsTeam(name: "Rangers", shortName: "NYR", city: "New York", league: .nhl, primaryColorHex: "#0038A8", secondaryColorHex: "#CE1126", logoEmoji: "🗽"),
        SportsTeam(name: "Flyers", shortName: "PHI", city: "Philadelphia", league: .nhl, primaryColorHex: "#F74902", secondaryColorHex: "#000000", logoEmoji: "🅿️"),
        SportsTeam(name: "Penguins", shortName: "PIT", city: "Pittsburgh", league: .nhl, primaryColorHex: "#000000", secondaryColorHex: "#FCB514", logoEmoji: "🐧"),
        SportsTeam(name: "Capitals", shortName: "WAS", city: "Washington", league: .nhl, primaryColorHex: "#C8102E", secondaryColorHex: "#041E42", logoEmoji: "🦅"),
        // Central
        SportsTeam(name: "Coyotes", shortName: "ARI", city: "Arizona", league: .nhl, primaryColorHex: "#8C2633", secondaryColorHex: "#E2D6B5", logoEmoji: "🐺"),
        SportsTeam(name: "Blackhawks", shortName: "CHI", city: "Chicago", league: .nhl, primaryColorHex: "#CF0A2C", secondaryColorHex: "#000000", logoEmoji: "🪶"),
        SportsTeam(name: "Avalanche", shortName: "COL", city: "Colorado", league: .nhl, primaryColorHex: "#6F263D", secondaryColorHex: "#236192", logoEmoji: "🏔️"),
        SportsTeam(name: "Stars", shortName: "DAL", city: "Dallas", league: .nhl, primaryColorHex: "#006847", secondaryColorHex: "#8F8F8C", logoEmoji: "⭐"),
        SportsTeam(name: "Wild", shortName: "MIN", city: "Minnesota", league: .nhl, primaryColorHex: "#154734", secondaryColorHex: "#A6192E", logoEmoji: "🌲"),
        SportsTeam(name: "Predators", shortName: "NSH", city: "Nashville", league: .nhl, primaryColorHex: "#FFB81C", secondaryColorHex: "#041E42", logoEmoji: "🐆"),
        SportsTeam(name: "Blues", shortName: "STL", city: "St. Louis", league: .nhl, primaryColorHex: "#002F87", secondaryColorHex: "#FCB514", logoEmoji: "🎵"),
        SportsTeam(name: "Jets", shortName: "WPG", city: "Winnipeg", league: .nhl, primaryColorHex: "#041E42", secondaryColorHex: "#004C97", logoEmoji: "✈️"),
        // Pacific
        SportsTeam(name: "Ducks", shortName: "ANA", city: "Anaheim", league: .nhl, primaryColorHex: "#F47A38", secondaryColorHex: "#B9975B", logoEmoji: "🦆"),
        SportsTeam(name: "Flames", shortName: "CGY", city: "Calgary", league: .nhl, primaryColorHex: "#C8102E", secondaryColorHex: "#F1BE48", logoEmoji: "🔥"),
        SportsTeam(name: "Oilers", shortName: "EDM", city: "Edmonton", league: .nhl, primaryColorHex: "#041E42", secondaryColorHex: "#FF4C00", logoEmoji: "🛢️"),
        SportsTeam(name: "Kings", shortName: "LA", city: "Los Angeles", league: .nhl, primaryColorHex: "#111111", secondaryColorHex: "#A2AAAD", logoEmoji: "👑"),
        SportsTeam(name: "Sharks", shortName: "SJ", city: "San Jose", league: .nhl, primaryColorHex: "#006D75", secondaryColorHex: "#EA7200", logoEmoji: "🦈"),
        SportsTeam(name: "Kraken", shortName: "SEA", city: "Seattle", league: .nhl, primaryColorHex: "#001628", secondaryColorHex: "#99D9D9", logoEmoji: "🦑"),
        SportsTeam(name: "Canucks", shortName: "VAN", city: "Vancouver", league: .nhl, primaryColorHex: "#00205B", secondaryColorHex: "#00843D", logoEmoji: "🐋"),
        SportsTeam(name: "Golden Knights", shortName: "VGK", city: "Vegas", league: .nhl, primaryColorHex: "#B4975A", secondaryColorHex: "#333F42", logoEmoji: "⚔️"),
    ]

    // MARK: - All Teams
    static var allTeams: [SportsTeam] {
        nflTeams + nbaTeams + mlbTeams + nhlTeams
    }

    // MARK: - Canonical (Supabase) UUID resolver
    //
    // The iOS-authoritative team UUID is computed via
    // `SportsTeam.stableID(league:shortName:)`, which keys SHA-256
    // off `"\(league.rawValue)_\(shortName)"`. `League.rawValue` is
    // UPPERCASE (e.g. "NFL"), so the iOS UUID for the Chiefs comes
    // from `SHA256("NFL_KC")`.
    //
    // Supabase canonical data (public.games, public.teams, future
    // ingest worker) keys league as LOWERCASE — both the
    // `teams_league_check` constraint and the seed scripts use
    // "nfl"/"nba"/"mlb"/"nhl". The deterministic UUIDs in
    // public.games.home_team_id / away_team_id and public.teams.id
    // are therefore derived from `SHA256("nfl_KC")` — a completely
    // different value than iOS computes for the same team.
    //
    // The clean cross-platform fix would be to align both sides on
    // one case (lowercase preferred — matches the migration CHECKs
    // and the rest of the API surface). But changing iOS's
    // `stableID` would orphan every persisted UUID in
    // UserPreferences, posts.team_id, etc. on every existing install.
    //
    // So this resolver does the bridging client-side: a precomputed
    // secondary index keyed by the *lowercase-derived* UUID points
    // at the same SportsTeam values. The unified
    // `team(byCanonicalId:)` consults both. Cost is one ~124-entry
    // dictionary lookup added per resolution; happens once per game
    // per refresh cycle.
    //
    // Future cleanup options (out of scope for this fix):
    //   • re-seed public.games + public.teams with the uppercase
    //     derivation, or
    //   • change `League` rawValues to lowercase + add an explicit
    //     `displayName` getter that returns "NFL"/"NBA" — and
    //     migrate any persisted data.

    /// Secondary lookup table keyed by the lowercase-league-form
    /// UUID. Built once on first access. Mirrors `team.id` -> team
    /// for every entry in `allTeams`, but with the UUID computed
    /// from `"<league.rawValue.lowercased())>_<shortName>"` instead
    /// of the iOS-authoritative uppercase form.
    private static let supabaseDerivedTeamIndex: [UUID: SportsTeam] = {
        var map: [UUID: SportsTeam] = [:]
        for team in allTeams {
            let key = "\(team.league.rawValue.lowercased())_\(team.shortName)"
            let digest = SHA256.hash(data: Data(key.utf8))
            var bytes = Array(digest.prefix(16))
            bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5-shape
            bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
            let id = UUID(uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            ))
            map[id] = team
        }
        return map
    }()

    /// Resolves a team UUID against either derivation flavor. Tries
    /// the iOS-authoritative `team(byId:)` first (uppercase-league
    /// derivation), then the Supabase-canonical lowercase index.
    /// Returns nil only when neither lookup hits — a true data gap.
    static func team(byCanonicalId id: UUID) -> SportsTeam? {
        if let team = team(byId: id) {
            return team
        }
        return supabaseDerivedTeamIndex[id]
    }

    static func teams(for league: League) -> [SportsTeam] {
        switch league {
        case .nfl: return nflTeams
        case .nba: return nbaTeams
        case .mlb: return mlbTeams
        case .nhl: return nhlTeams
        }
    }

    static func team(byId id: UUID) -> SportsTeam? {
        allTeams.first { $0.id == id }
    }

    /// Look up a team by its `shortName` within a given league. Used by the
    /// API mapping layer to resolve backend team identifiers (e.g. "BUF" + .nfl)
    /// into our local `SportsTeam` (with colors, emoji, full name).
    static func team(byShortName shortName: String, league: League) -> SportsTeam? {
        teams(for: league).first { $0.shortName.caseInsensitiveCompare(shortName) == .orderedSame }
    }
}
