import Foundation
import Combine

/// Singleton that polls the configured `LiveScoreProvider` and publishes the
/// current set of live games. View models subscribe to `$liveGames`; they do
/// not own a timer or a provider.
///
/// Lifecycle:
///   - `start()` is called once on app launch.
///   - `pause()` / `resume()` are driven by scenePhase from the App.
///   - `boostPolling()` switches to the active interval while the user is in
///     a game chat room; `restoreDefaultPolling()` reverts.
///   - `refreshNow()` is wired to pull-to-refresh and the manual refresh button.
@MainActor
final class LiveScoreService: ObservableObject {
    static let shared = LiveScoreService()

    @Published private(set) var liveGames: [LiveGame] = []
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var lastError: LiveScoreError?
    @Published private(set) var isLoading: Bool = false

    private let provider: LiveScoreProvider
    private var timer: Timer?
    private var currentInterval: TimeInterval
    private var inFlightTask: Task<Void, Never>?
    private var isPaused: Bool = false

    private init(provider: LiveScoreProvider? = nil) {
        self.provider = provider ?? Self.makeDefaultProvider()
        self.currentInterval = AppConfig.pollingIntervalDefault
    }

    private static func makeDefaultProvider() -> LiveScoreProvider {
        AppConfig.useMockProvider ? MockLiveScoreProvider() : RemoteLiveScoreProvider()
    }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        isPaused = false
        scheduleTimer(interval: currentInterval)
        Task { await self.fetch() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        timer?.invalidate()
        timer = nil
        inFlightTask?.cancel()
        inFlightTask = nil
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        scheduleTimer(interval: currentInterval)
        Task { await self.fetch() }
    }

    // MARK: - Polling cadence

    func boostPolling() {
        boostPolling(AppConfig.pollingIntervalActive)
    }

    func boostPolling(_ interval: TimeInterval) {
        guard interval != currentInterval else { return }
        currentInterval = interval
        if !isPaused { scheduleTimer(interval: interval) }
    }

    func restoreDefaultPolling() {
        guard currentInterval != AppConfig.pollingIntervalDefault else { return }
        currentInterval = AppConfig.pollingIntervalDefault
        if !isPaused { scheduleTimer(interval: currentInterval) }
    }

    // MARK: - Manual refresh

    func refreshNow() async {
        await fetch()
    }

    // MARK: - Internals

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.fetch() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func fetch() async {
        // Coalesce concurrent calls: if a fetch is already in flight, skip.
        if inFlightTask != nil { return }
        isLoading = true

        let task = Task { @MainActor [provider] in
            do {
                let games = try await provider.fetchLiveGames()
                self.liveGames = games
                self.lastUpdated = Date()
                self.lastError = nil
            } catch let error as LiveScoreError {
                self.lastError = error
            } catch {
                self.lastError = .transport(error)
            }
            self.isLoading = false
            self.inFlightTask = nil
        }
        inFlightTask = task
        await task.value
    }
}

// MARK: - Team-targeted lookups
//
// The team chat scoreboard needs to know which (if any) live game involves
// a given team. The predicate lives once on `Array<LiveGame>`; the service
// exposes an instance accessor for one-shot reads and a Combine publisher
// for view models that want to react to every poll.

extension Array where Element == LiveGame {
    /// First live game involving `team` as either home or away side, if any.
    func first(matching team: SportsTeam) -> LiveGame? {
        first { $0.homeTeam.id == team.id || $0.awayTeam.id == team.id }
    }
}

extension LiveScoreService {
    /// Currently-active live game involving `team` from the latest poll.
    /// Returns `nil` when the team isn't playing in the current snapshot.
    func liveGame(for team: SportsTeam) -> LiveGame? {
        liveGames.first(matching: team)
    }

    /// Stream of the currently-active live game for `team`. Re-emits whenever
    /// the polled set of live games changes (deduplicated). View models sink
    /// this onto an `@Published var liveGame: LiveGame?` so the team chat
    /// scoreboard updates with each poll.
    func liveGamePublisher(for team: SportsTeam) -> AnyPublisher<LiveGame?, Never> {
        $liveGames
            .map { $0.first(matching: team) }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
}
