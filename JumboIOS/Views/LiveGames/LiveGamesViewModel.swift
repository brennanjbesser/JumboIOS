import SwiftUI
import Combine

// MARK: - Supporting Models

struct UpcomingGame: Identifiable {
    let id: UUID
    let homeTeam: SportsTeam
    let awayTeam: SportsTeam
    let startTime: Date
    let league: League
}

struct TrendingRoom: Identifiable {
    let id: UUID
    let title: String
    let activeUsers: Int
    let emoji: String
    let accentColor: Color
}

enum TeamLiveStatus {
    case liveNow
    case newPosts
    case pregame

    var text: String {
        switch self {
        case .liveNow: return "Live now"
        case .newPosts: return "New posts"
        case .pregame: return "Pregame"
        }
    }

    var color: Color {
        switch self {
        case .liveNow: return FanChatTheme.liveIndicator
        case .newPosts: return FanChatTheme.neonCyan
        case .pregame: return FanChatTheme.textTertiary
        }
    }
}

extension LiveGame: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - View Model

@MainActor
class LiveGamesViewModel: ObservableObject {
    @Published var liveGames: [LiveGame] = []
    @Published var upcomingGames: [UpcomingGame] = []
    @Published var trendingRooms: [TrendingRoom] = []
    @Published var notifiedGameIds: Set<UUID> = []

    private var fanCounts: [UUID: Int] = [:]
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupUpcomingAndTrendingMockData()
        bindToLiveScoreService()
    }

    // MARK: - Live Score Subscription

    private func bindToLiveScoreService() {
        let service = LiveScoreService.shared
        // Seed with whatever the service has cached so the view isn't empty
        // for the first poll cycle.
        liveGames = service.liveGames
        ensureFanCounts(for: liveGames)

        service.$liveGames
            .receive(on: DispatchQueue.main)
            .sink { [weak self] games in
                guard let self else { return }
                self.liveGames = games
                self.ensureFanCounts(for: games)
            }
            .store(in: &cancellables)
    }

    private func ensureFanCounts(for games: [LiveGame]) {
        for game in games where fanCounts[game.id] == nil {
            // Pseudo-stable seed per game so counts don't bounce on each poll.
            fanCounts[game.id] = abs(game.id.hashValue) % 4000 + 500
        }
    }

    // MARK: - Upcoming + Trending mock data
    // Live games now come from LiveScoreService. Upcoming + trending rooms
    // remain mock for V1 — they'll be replaced by their own backend endpoints
    // post-launch.

    private func setupUpcomingAndTrendingMockData() {
        let nba = TeamDatabase.nbaTeams
        let nhl = TeamDatabase.nhlTeams
        let mlb = TeamDatabase.mlbTeams
        let nfl = TeamDatabase.nflTeams

        // Upcoming Games
        let now = Date()

        if let dodgers = mlb.first(where: { $0.shortName == "LAD" }),
           let yankees = mlb.first(where: { $0.shortName == "NYY" }) {
            upcomingGames.append(UpcomingGame(
                id: UUID(), homeTeam: dodgers, awayTeam: yankees,
                startTime: now.addingTimeInterval(2 * 3600), league: .mlb
            ))
        }

        if let heat = nba.first(where: { $0.shortName == "MIA" }),
           let mavs = nba.first(where: { $0.shortName == "DAL" }) {
            upcomingGames.append(UpcomingGame(
                id: UUID(), homeTeam: heat, awayTeam: mavs,
                startTime: now.addingTimeInterval(3 * 3600), league: .nba
            ))
        }

        if let steelers = nfl.first(where: { $0.shortName == "PIT" }),
           let bengals = nfl.first(where: { $0.shortName == "CIN" }) {
            upcomingGames.append(UpcomingGame(
                id: UUID(), homeTeam: steelers, awayTeam: bengals,
                startTime: now.addingTimeInterval(4.5 * 3600), league: .nfl
            ))
        }

        if let penguins = nhl.first(where: { $0.shortName == "PIT" }),
           let sabres = nhl.first(where: { $0.shortName == "BUF" }) {
            upcomingGames.append(UpcomingGame(
                id: UUID(), homeTeam: penguins, awayTeam: sabres,
                startTime: now.addingTimeInterval(5 * 3600), league: .nhl
            ))
        }

        if let redsox = mlb.first(where: { $0.shortName == "BOS" }),
           let orioles = mlb.first(where: { $0.shortName == "BAL" }) {
            upcomingGames.append(UpcomingGame(
                id: UUID(), homeTeam: redsox, awayTeam: orioles,
                startTime: now.addingTimeInterval(6 * 3600), league: .mlb
            ))
        }

        // Trending Rooms
        trendingRooms = [
            TrendingRoom(id: UUID(), title: "NFL RedZone Chat", activeUsers: 3241, emoji: "🏈", accentColor: FanChatTheme.neonOrange),
            TrendingRoom(id: UUID(), title: "Trade Deadline Talk", activeUsers: 1832, emoji: "📢", accentColor: FanChatTheme.neonCyan),
            TrendingRoom(id: UUID(), title: "March Madness", activeUsers: 2510, emoji: "🏀", accentColor: FanChatTheme.neonPurple),
            TrendingRoom(id: UUID(), title: "Playoff Picture", activeUsers: 1145, emoji: "🏆", accentColor: FanChatTheme.neonGreen),
            TrendingRoom(id: UUID(), title: "Draft Rumors", activeUsers: 892, emoji: "📰", accentColor: FanChatTheme.neonPink),
        ]
    }

    // MARK: - Helpers

    func refresh() async {
        await LiveScoreService.shared.refreshNow()
    }


    func fanCount(for game: LiveGame) -> Int {
        fanCounts[game.id] ?? (abs(game.id.hashValue) % 3000 + 500)
    }

    func teamStatus(for team: SportsTeam) -> TeamLiveStatus {
        if liveGames.contains(where: { $0.homeTeam.id == team.id || $0.awayTeam.id == team.id }) {
            return .liveNow
        }
        if upcomingGames.contains(where: { $0.homeTeam.id == team.id || $0.awayTeam.id == team.id }) {
            return .pregame
        }
        return .newPosts
    }

    func toggleNotification(for gameId: UUID) {
        if notifiedGameIds.contains(gameId) {
            notifiedGameIds.remove(gameId)
            NotificationService.shared.cancelGameNotification(gameId: gameId)
        } else {
            notifiedGameIds.insert(gameId)
            // Schedule a real local notification for game start
            if let game = upcomingGames.first(where: { $0.id == gameId }) {
                NotificationService.shared.scheduleGameNotification(
                    gameId: gameId,
                    homeTeam: game.homeTeam.shortName,
                    awayTeam: game.awayTeam.shortName,
                    league: game.league.displayName,
                    startTime: game.startTime
                )
            }
        }
    }

    func formattedStartTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    func formattedFanCount(_ count: Int) -> String {
        if count >= 1000 {
            let thousands = Double(count) / 1000.0
            return String(format: "%.1fk", thousands)
        }
        return "\(count)"
    }
}
