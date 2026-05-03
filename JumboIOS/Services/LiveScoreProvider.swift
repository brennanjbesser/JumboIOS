import Foundation

// MARK: - Provider abstraction
//
// LiveScoreService talks only to this protocol. Swap out the concrete
// implementation (mock / remote / future GraphQL / future WebSocket) without
// touching view models or views.

protocol LiveScoreProvider: Sendable {
    func fetchLiveGames() async throws -> [LiveGame]
}

enum LiveScoreError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from live scores backend."
        case .httpStatus(let code): return "Live scores backend returned HTTP \(code)."
        case .decoding(let error): return "Could not decode live scores response: \(error.localizedDescription)"
        case .transport(let error): return "Network error fetching live scores: \(error.localizedDescription)"
        }
    }
}

// MARK: - Remote provider (calls JUMBO backend)

struct RemoteLiveScoreProvider: LiveScoreProvider {
    let baseURL: URL
    let path: String
    let session: URLSession

    init(
        baseURL: URL = AppConfig.backendBaseURL,
        path: String = AppConfig.liveGamesEndpoint,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.path = path
        self.session = session
    }

    func fetchLiveGames() async throws -> [LiveGame] {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.timeoutInterval = AppConfig.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LiveScoreError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LiveScoreError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveScoreError.httpStatus(http.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(LiveGameAPIResponse.self, from: data)
            return decoded.toLiveGames()
        } catch {
            throw LiveScoreError.decoding(error)
        }
    }
}

// MARK: - Mock provider (dev / offline fallback)
//
// Returns a fixed slate of games with light score jitter on each call so the
// UI can be exercised without the backend running. Behind `AppConfig.useMockProvider`.

struct MockLiveScoreProvider: LiveScoreProvider {
    func fetchLiveGames() async throws -> [LiveGame] {
        // Tiny artificial latency so loading states actually show in dev.
        try? await Task.sleep(nanoseconds: 200_000_000)

        let dtos: [LiveGameDTO] = [
            LiveGameDTO(id: "nfl-mock-1", league: "NFL", status: "live",
                        homeTeamId: "KC", awayTeamId: "BAL",
                        homeScore: 21 + Self.jitter(), awayScore: 17 + Self.jitter(),
                        period: "3rd Quarter", timeRemaining: "8:42",
                        startTime: nil, lastUpdated: nil),
            LiveGameDTO(id: "nfl-mock-2", league: "NFL", status: "live",
                        homeTeamId: "DAL", awayTeamId: "PHI",
                        homeScore: 10, awayScore: 14 + Self.jitter(),
                        period: "2nd Quarter", timeRemaining: "2:15",
                        startTime: nil, lastUpdated: nil),
            LiveGameDTO(id: "nfl-mock-3", league: "NFL", status: "halftime",
                        homeTeamId: "GB", awayTeamId: "CHI",
                        homeScore: 17, awayScore: 13,
                        period: "Halftime", timeRemaining: "",
                        startTime: nil, lastUpdated: nil),
            LiveGameDTO(id: "nba-mock-1", league: "NBA", status: "live",
                        homeTeamId: "LAL", awayTeamId: "BOS",
                        homeScore: 87 + Self.jitter(), awayScore: 91 + Self.jitter(),
                        period: "4th Quarter", timeRemaining: "4:23",
                        startTime: nil, lastUpdated: nil),
            LiveGameDTO(id: "nba-mock-2", league: "NBA", status: "live",
                        homeTeamId: "GSW", awayTeamId: "MIL",
                        homeScore: 28, awayScore: 24 + Self.jitter(),
                        period: "1st Quarter", timeRemaining: "3:05",
                        startTime: nil, lastUpdated: nil),
            LiveGameDTO(id: "nhl-mock-1", league: "NHL", status: "live",
                        homeTeamId: "BOS", awayTeamId: "NYR",
                        homeScore: 2, awayScore: 3,
                        period: "2nd Period", timeRemaining: "11:30",
                        startTime: nil, lastUpdated: nil),
        ]
        return dtos.compactMap { $0.toLiveGame() }
    }

    private static func jitter() -> Int { Int.random(in: 0...3) }
}
