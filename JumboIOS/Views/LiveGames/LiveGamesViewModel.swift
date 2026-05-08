import SwiftUI
import Combine
import OSLog
import Supabase

private let liveLogger = Logger(subsystem: "com.jumbo", category: "live-page")

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

    /// LATCHING flag — once set true (by a successful canonical
    /// fetch with ≥1 row), it STAYS true for the rest of the VM's
    /// life unless the circuit-breaker explicitly resets it. While
    /// true, the LiveScoreService → liveGames Combine sink is
    /// silenced so mock-provider polls can never overwrite canonical
    /// state, even when a subsequent canonical refresh returns an
    /// empty array (a legitimate "no live games right now") or a
    /// thrown error (transient network blip). This is the entire
    /// point of the canonical/mock cutover: the moment we have
    /// trusted Supabase data, we trust it for the rest of the
    /// session.
    private var useCanonicalLiveGames = false

    /// Mirror of `useCanonicalLiveGames` for the upcoming list.
    /// `upcomingGames` isn't bound to a Combine publisher today
    /// (the init-time mock fixtures are never re-applied), but the
    /// latching semantics matter for refresh cycles: once canonical
    /// upcoming activates, an empty refresh result reflects reality
    /// (e.g., a kickoff just happened — drop the row) instead of
    /// silently keeping stale data.
    private var useCanonicalUpcomingGames = false

    // MARK: - Master Supabase toggle
    //
    // Single feature flag for the canonical-data path. Flip to
    // `false` to disable Supabase fetches entirely — the LIVE page
    // then runs purely on the existing mock systems
    // (`LiveScoreService` + `MockLiveScoreProvider` for live games,
    // `setupUpcomingAndTrendingMockData()` for COMING UP /
    // TRENDING). With the flag off:
    //   • `loadGames()` early-returns; `useCanonical*` flags stay
    //     false; the mock-provider Combine sink is never silenced.
    //   • The 15s polling timer never starts (the polling-management
    //     block at the end of `loadGames()` is unreachable).
    //   • `refresh()` still triggers the mock provider's
    //     `refreshNow()`, so pull-to-refresh keeps working.
    //
    // Default `true` matches today's behavior (canonical-when-
    // available, mock-as-fallback). No code is removed when the flag
    // is flipped — every Supabase code path is gated by this single
    // boolean.
    private let useSupabaseGames: Bool = true

    // MARK: - Canonical polling state

    /// Background polling Timer. Single instance — `startCanonicalPolling()`
    /// invalidates any existing timer before scheduling a new one, so
    /// re-entry can never produce duplicate timers.
    private var canonicalPollTimer: Timer?

    /// Count of consecutive `loadGames()` cycles where BOTH canonical
    /// fetches threw. Reset to 0 on any successful (non-throwing) fetch
    /// — even one returning an empty array. Drives the
    /// `canonicalFailureThreshold`-based polling shutoff so a dead
    /// Supabase doesn't burn cycles forever.
    private var canonicalConsecutiveFailures: Int = 0

    /// Coalescing guard for `loadGames()`. The timer fires every 15s,
    /// the init kicks off an immediate fetch, and pull-to-refresh
    /// also calls in — so concurrent invocations are possible. The
    /// flag flips synchronously (before any `await`) on the
    /// MainActor, so only one cycle runs at a time.
    private var loadGamesInFlight = false

    /// Background poll cadence. 15s matches the spec.
    private static let canonicalPollInterval: TimeInterval = 15

    /// Number of consecutive failed cycles before background polling
    /// is suspended. After threshold, the timer is torn down; mock
    /// fallback is already in effect on each individual failure
    /// (useCanonical* flags get flipped off), so the user is never
    /// left with a blank UI.
    private static let canonicalFailureThreshold: Int = 3

    // MARK: - Games realtime subscription state

    /// Long-lived Postgres realtime channel listening for INSERT and
    /// UPDATE on `public.games`. Single instance — `start()` checks
    /// `gamesSubscribed` before opening another. Tear-down clears
    /// this and the listener tasks together.
    private var gamesRealtimeChannel: RealtimeChannelV2?

    /// Listener task draining the INSERT stream off `gamesRealtimeChannel`.
    private var gamesInsertListenerTask: Task<Void, Never>?

    /// Listener task draining the UPDATE stream off `gamesRealtimeChannel`.
    private var gamesUpdateListenerTask: Task<Void, Never>?

    /// Status watcher — observes `channel.statusChange` and triggers
    /// `attemptGamesReconnect` whenever the channel drops to
    /// `.unsubscribed` outside of an intentional teardown. Mirrors
    /// `RemoteChatService.watchUserProfilesChannelStatus`.
    private var gamesWatcherTask: Task<Void, Never>?

    /// Idempotency guard for `startGamesRealtimeSubscription()`.
    /// Set true after a successful subscribe, cleared by reconnect /
    /// teardown.
    private var gamesSubscribed: Bool = false

    /// Reentrancy guard on `attemptGamesReconnect`. Prevents two
    /// concurrent reconnect cycles (e.g., a watcher trigger arriving
    /// while a manual reconnect is in flight).
    private var gamesReconnectInFlight: Bool = false

    init() {
        setupUpcomingAndTrendingMockData()
        bindToLiveScoreService()

        // Kick off the canonical Supabase fetch in the background.
        // If it succeeds with data, `loadGames()` flips the
        // useCanonical* flags and replaces the published arrays. If
        // it fails or returns empty, the mock paths set up just
        // above continue to drive the UI exactly as today.
        Task { [weak self] in
            await self?.loadGames()
        }

        // Start the realtime subscription on `public.games`. INSERT
        // and UPDATE events trigger a clean re-fetch via loadGames()
        // — we do NOT mutate the published arrays from payload diffs
        // yet (per spec). Gated on the master toggle so disabling
        // Supabase shuts off realtime too.
        Task { [weak self] in
            await self?.startGamesRealtimeSubscription()
        }
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
                // Don't let mock-provider polling overwrite canonical
                // data once `loadGames()` has installed it. When
                // canonical isn't in play this still drives the UI
                // exactly as today.
                guard !self.useCanonicalLiveGames else { return }
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

    // MARK: - Canonical Supabase load (with mock fallback)
    //
    // Read-side bridge from `public.games` (via SportsGameService) into
    // the legacy in-memory UI models (LiveGame / UpcomingGame). The UI
    // layer is intentionally NOT migrated yet — this keeps the bridge
    // localized to the VM. Behavior:
    //
    //   1. Fetch live + upcoming games concurrently from Supabase.
    //   2. Map each Sports.Game into a LiveGame / UpcomingGame using
    //      TeamDatabase.team(byId:) so home/away SportsTeam values
    //      come from the same in-app team list the UI already
    //      renders. Rows whose team UUIDs aren't in TeamDatabase are
    //      silently skipped (logged) — happens if Supabase ever
    //      seeds a team the iOS bundle doesn't know about yet.
    //   3. If the canonical list is non-empty, install it and flip
    //      the corresponding useCanonical* flag so the mock-provider
    //      Combine sink doesn't overwrite it.
    //   4. If the canonical list is empty (or the fetch threw), flip
    //      the flag off so mock data continues to drive the UI on the
    //      next poll cycle. The view never goes blank — mock state
    //      from init() and bindToLiveScoreService() stays in place.

    /// Fetch canonical games from Supabase and, if any are returned,
    /// replace the published arrays. Falls back to the existing mock
    /// data on error or empty result. Safe to call repeatedly — a
    /// coalescing guard prevents overlapping cycles.
    ///
    /// Side effects:
    ///   • `useCanonicalLive/UpcomingGames` flags flip on each call
    ///     (drive the LiveScoreService Combine sink's mock-vs-canonical
    ///     decision).
    ///   • `canonicalConsecutiveFailures` increments when both fetches
    ///     throw, resets on any success (even an empty success).
    ///   • Background polling timer starts/stops based on the
    ///     post-cycle state. See the polling-management block at the
    ///     bottom of the function.
    func loadGames() async {
        // Master toggle: when false, skip Supabase entirely. Mock
        // continues to drive the UI exactly as before this code
        // landed.
        guard useSupabaseGames else {
            liveLogger.info("ℹ️ useSupabaseGames=false — Supabase fetch disabled, mock continues to drive UI")
            return
        }

        // Coalesce: the 15s timer + init() Task + pull-to-refresh can
        // all race. Bail if a cycle is already running.
        guard !loadGamesInFlight else {
            liveLogger.debug("loadGames already in flight — coalescing skip")
            return
        }
        loadGamesInFlight = true
        defer { loadGamesInFlight = false }

        // Run both fetches in parallel — they don't depend on each
        // other and we don't want to wait sequentially.
        async let liveResult     = fetchCanonicalLiveGames()
        async let upcomingResult = fetchCanonicalUpcomingGames()
        let (canonicalLive, canonicalUpcoming) = await (liveResult, upcomingResult)

        // ---- Failure tracking
        // `nil` means the fetch threw; an empty array means Supabase
        // is healthy but currently has no rows. Only the former
        // counts as a failure for circuit-breaker purposes.
        let bothFailed = (canonicalLive == nil) && (canonicalUpcoming == nil)
        if bothFailed {
            canonicalConsecutiveFailures += 1
            liveLogger.warning("⚠️ Canonical fetch failed (\(self.canonicalConsecutiveFailures)/\(Self.canonicalFailureThreshold))")
        } else {
            if canonicalConsecutiveFailures > 0 {
                liveLogger.info("✅ Canonical fetch recovered after \(self.canonicalConsecutiveFailures) failure(s)")
            }
            canonicalConsecutiveFailures = 0
        }

        // ---- LIVE NOW
        //
        // Three states matter:
        //   (a) success with ≥1 row     → activate (or refresh canonical)
        //   (b) already-activated +
        //       empty/throw this cycle  → keep canonical authoritative
        //                                  (don't fall back to mock)
        //   (c) not yet activated +
        //       empty/throw             → fall back to mock
        //
        // Critically: the (b) branch leaves `useCanonicalLiveGames`
        // TRUE so the mock Combine sink stays blocked. On a transient
        // empty refresh (e.g., a status-flip mid-cycle) we don't
        // briefly show mock data and then snap back to canonical —
        // we just hold canonical or reflect the empty refresh.
        if let canonicalLive, !canonicalLive.isEmpty {
            let firstActivation = !useCanonicalLiveGames
            useCanonicalLiveGames = true
            liveGames = canonicalLive
            ensureFanCounts(for: canonicalLive)
            if firstActivation {
                liveLogger.info("✅ canonical LIVE NOW activated — \(canonicalLive.count) game(s) (mock sink now blocked)")
            } else {
                liveLogger.info("✅ canonical LIVE NOW applied — \(canonicalLive.count) game(s)")
            }
        } else if useCanonicalLiveGames {
            // Already-activated path — canonical stays authoritative.
            if let canonicalLive {
                // Empty success: legitimately zero live games right
                // now. Reflect it; mock stays blocked.
                liveGames = canonicalLive   // = []
                liveLogger.info("✅ canonical LIVE NOW applied — 0 game(s) (no live games at the moment)")
            } else {
                // Threw: preserve previous canonical, don't blank,
                // don't fall back. Failure-tracking handles the
                // circuit-breaker reset if errors persist.
                liveLogger.warning("⚠️ canonical LIVE NOW fetch threw — preserving previous \(self.liveGames.count) game(s); mock stays blocked")
            }
        } else {
            // Pre-activation path — mock fallback is allowed.
            // useCanonicalLiveGames stays false so the bound mock
            // Combine sink continues driving liveGames.
            liveLogger.info("ℹ️ LIVE NOW mock fallback active (canonical not yet activated)")
        }

        // ---- COMING UP
        // Same three-state logic as LIVE NOW. There's no Combine
        // sink for upcoming, but the latch still matters: on an
        // empty refresh after activation, we must apply [] (game
        // started → row drops off) instead of leaving stale data.
        if let canonicalUpcoming, !canonicalUpcoming.isEmpty {
            let firstActivation = !useCanonicalUpcomingGames
            useCanonicalUpcomingGames = true
            upcomingGames = canonicalUpcoming
            if firstActivation {
                liveLogger.info("✅ canonical COMING UP activated — \(canonicalUpcoming.count) game(s)")
            } else {
                liveLogger.info("✅ canonical COMING UP applied — \(canonicalUpcoming.count) game(s)")
            }
        } else if useCanonicalUpcomingGames {
            if let canonicalUpcoming {
                upcomingGames = canonicalUpcoming   // = []
                liveLogger.info("✅ canonical COMING UP applied — 0 game(s) (no upcoming games)")
            } else {
                liveLogger.warning("⚠️ canonical COMING UP fetch threw — preserving previous \(self.upcomingGames.count) game(s)")
            }
        } else {
            liveLogger.info("ℹ️ COMING UP mock fallback active (canonical not yet activated)")
        }

        // ---- Polling management
        //
        // Three reasons to keep polling:
        //   (a) Canonical data is currently in play — keep refreshing
        //       so scores/statuses/clocks update without manual pulls.
        //   (b) We're inside the failure-retry window (had errors but
        //       haven't hit the threshold yet) — give Supabase a few
        //       cycles to recover before giving up.
        //
        // Reasons to stop polling:
        //   • Hit the failure threshold — log and shut off background
        //     polling. Mock continues to drive the UI; user can pull
        //     to refresh to retry canonical later.
        //   • Healthy fetch but no canonical data anywhere (both
        //     arrays empty AND no failures) — nothing to refresh.
        if canonicalConsecutiveFailures >= Self.canonicalFailureThreshold {
            // Circuit-breaker tripped: the backend is genuinely
            // unreachable for ≥45s. Unlatch the canonical flags so
            // mock can take over and visually fill the page; stop
            // polling so we're not burning cycles. A subsequent
            // manual refresh (or background→foreground cycle) can
            // re-attempt activation.
            liveLogger.error("❌ Circuit-breaker tripped after \(self.canonicalConsecutiveFailures) consecutive failures — unlatching canonical flags, mock fallback now active, polling stopped")
            canonicalConsecutiveFailures = 0
            useCanonicalLiveGames = false
            useCanonicalUpcomingGames = false
            stopCanonicalPolling()
        } else if useCanonicalLiveGames || useCanonicalUpcomingGames || canonicalConsecutiveFailures > 0 {
            startCanonicalPolling()
        } else {
            stopCanonicalPolling()
        }
    }

    // MARK: - Canonical polling timer

    /// Schedules the 15s repeating Timer if one isn't already running.
    /// Idempotent — `canonicalPollTimer` is checked first so calling
    /// repeatedly inside a hot `loadGames()` cycle never produces
    /// duplicate timers. Captures `[weak self]` so the timer doesn't
    /// retain the view model.
    private func startCanonicalPolling() {
        guard canonicalPollTimer == nil else { return }
        let interval = Self.canonicalPollInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // The Timer fires on whatever run loop it's added to (we
            // add to .main below). Hop to MainActor with weak-self so
            // a stale fire after dealloc is harmless.
            Task { @MainActor [weak self] in
                await self?.loadGames()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        canonicalPollTimer = timer
        liveLogger.info("⏱️ Canonical polling started (every \(Int(interval))s)")
    }

    /// Tears down the polling Timer. Idempotent — guards on nil so
    /// repeated calls are no-ops.
    private func stopCanonicalPolling() {
        guard canonicalPollTimer != nil else { return }
        canonicalPollTimer?.invalidate()
        canonicalPollTimer = nil
        liveLogger.info("⏹️ Canonical polling stopped")
    }

    // MARK: - Games realtime subscription
    //
    // Single Postgres realtime channel watching `public.games` for
    // INSERT and UPDATE. Any event triggers `loadGames()`, which
    // re-fetches from Supabase and re-publishes the legacy UI arrays.
    //
    // We do NOT decode the payload or apply diffs locally — per spec,
    // the iOS side stays purely re-fetch-driven for now. The benefit
    // is simplicity (no payload-shape coupling) and correctness
    // (re-fetch always reflects exactly what `SportsGameService`
    // would return on a manual call, including server-side filters).
    //
    // Lifecycle:
    //   • init   → start (gated on useSupabaseGames)
    //   • deinit → stop  (cancels tasks + removes channel)
    //   • channel drop → attemptGamesReconnect via watcher
    //
    // PREREQUISITE: `public.games` must be on the supabase_realtime
    // publication for events to fan out. Mirror the pattern in
    // supabase_migration_users_realtime.sql:
    //     ALTER PUBLICATION supabase_realtime ADD TABLE public.games;
    //     ALTER TABLE public.games REPLICA IDENTITY FULL;
    // Until that's run, this subscription connects but receives zero
    // events — the canonical poll timer continues to drive updates,
    // and mock fallback still works on its own.

    /// Idempotently subscribe to INSERT + UPDATE on `public.games`.
    /// No-op when `useSupabaseGames == false` or already subscribed.
    func startGamesRealtimeSubscription() async {
        guard useSupabaseGames else {
            liveLogger.info("ℹ️ games realtime: useSupabaseGames=false — skipping subscription")
            return
        }
        guard !gamesSubscribed, gamesRealtimeChannel == nil else {
            liveLogger.debug("ℹ️ games realtime: already subscribed — skipping")
            return
        }
        guard let client = SupabaseClientProvider.shared.client else {
            liveLogger.error("❌ games realtime: Supabase client unavailable — cannot subscribe")
            return
        }

        let channel = client.realtimeV2.channel("public:games")

        // Two streams on the same channel — INSERT and UPDATE — so
        // we don't miss new game rows nor live score / status flips.
        // DELETE is intentionally not subscribed: the lifecycle
        // worker uses status='closed'/'archived' to retire games,
        // never hard-deletes.
        let inserts = channel.postgresChange(
            InsertAction.self,
            schema: "public",
            table: "games"
        )
        let updates = channel.postgresChange(
            UpdateAction.self,
            schema: "public",
            table: "games"
        )

        await channel.subscribe()
        liveLogger.info("✅ games realtime: subscription connected (channel=public:games, schema=public, table=games, events=INSERT+UPDATE)")

        // Drain INSERT events.
        let insertTask = Task { [weak self] in
            for await _ in inserts {
                guard let self else { return }
                await self.handleGamesRealtimeChange(kind: "INSERT")
            }
            liveLogger.debug("🟡 games realtime: INSERT listener exited")
        }

        // Drain UPDATE events. Most score / status changes flow
        // through this stream once an ingest worker is wired up.
        let updateTask = Task { [weak self] in
            for await _ in updates {
                guard let self else { return }
                await self.handleGamesRealtimeChange(kind: "UPDATE")
            }
            liveLogger.debug("🟡 games realtime: UPDATE listener exited")
        }

        // Watch the channel's status stream so we can self-heal on
        // mid-session drops (network blip, server restart, app
        // foregrounding from a long suspension).
        let watcher = watchGamesChannelStatus(channel: channel)

        gamesRealtimeChannel    = channel
        gamesInsertListenerTask = insertTask
        gamesUpdateListenerTask = updateTask
        gamesWatcherTask        = watcher
        gamesSubscribed         = true
    }

    /// Tear down the realtime channel + listener tasks. Idempotent.
    /// Called from `attemptGamesReconnect` and `deinit`.
    func stopGamesRealtimeSubscription() async {
        gamesInsertListenerTask?.cancel()
        gamesInsertListenerTask = nil
        gamesUpdateListenerTask?.cancel()
        gamesUpdateListenerTask = nil
        gamesWatcherTask?.cancel()
        gamesWatcherTask = nil
        if let channel = gamesRealtimeChannel,
           let client = SupabaseClientProvider.shared.client {
            await client.realtimeV2.removeChannel(channel)
            liveLogger.info("⏹️ games realtime: subscription disconnected (channel removed)")
        }
        gamesRealtimeChannel = nil
        gamesSubscribed      = false
    }

    /// Per-channel watcher. Triggers `attemptGamesReconnect` whenever
    /// the channel flips to `.unsubscribed` outside of an intentional
    /// teardown. Cancelled and rebuilt on each reconnect cycle so it
    /// always points at the current channel.
    private func watchGamesChannelStatus(channel: RealtimeChannelV2) -> Task<Void, Never> {
        return Task { [weak self] in
            liveLogger.debug("🟣 games realtime watcher: STARTED — initial status=\(String(describing: channel.status))")
            for await newStatus in channel.statusChange {
                liveLogger.debug("🟣 games realtime watcher: status → \(String(describing: newStatus))")
                if Task.isCancelled { return }
                guard let self else { return }
                if newStatus == .unsubscribed {
                    liveLogger.error("⚠️ games realtime: channel DROPPED — triggering reconnect")
                    await self.attemptGamesReconnect(trigger: "watcher")
                }
            }
            liveLogger.debug("🟣 games realtime watcher: stream finished, EXITED")
        }
    }

    /// Reentrancy-guarded teardown + restart. Mirrors the pattern in
    /// `RemoteChatService.attemptUserProfilesReconnect`. Resets
    /// `gamesSubscribed` so the subsequent start() actually opens a
    /// new channel rather than no-op'ing on the stale flag.
    private func attemptGamesReconnect(trigger: String) async {
        guard !gamesReconnectInFlight else {
            liveLogger.debug("🔁 games realtime reconnect (\(trigger)): already in flight, skipping")
            return
        }
        gamesReconnectInFlight = true
        defer { gamesReconnectInFlight = false }

        liveLogger.info("🔁 games realtime reconnect (\(trigger)): tearing down + re-subscribing")
        await stopGamesRealtimeSubscription()
        await startGamesRealtimeSubscription()

        let recoveredStatus = String(describing: gamesRealtimeChannel?.status as Any)
        if gamesRealtimeChannel != nil {
            liveLogger.info("✅ games realtime reconnect (\(trigger)): subscription restored (status=\(recoveredStatus))")
        } else {
            liveLogger.error("❌ games realtime reconnect (\(trigger)): failed to restore subscription")
        }

        // Best-effort: trigger a refresh so any events that fired
        // while we were disconnected don't go missed.
        await loadGames()
    }

    /// Realtime event handler. Logs the receipt + the refresh
    /// trigger; loadGames() handles its own success/error logging.
    private func handleGamesRealtimeChange(kind: String) async {
        liveLogger.info("📡 games realtime: payload received (kind=\(kind))")
        liveLogger.info("🔄 games realtime: refresh triggered")
        await loadGames()
        liveLogger.info("✅ games realtime: refresh completed")
    }

    deinit {
        // Last-resort cleanup. Without this, the Timer would keep
        // firing in the run loop (the closure captures weak-self so
        // it's harmless once self is gone, but the Timer itself
        // would leak). Synchronous invalidate() is safe to call from
        // deinit; the Timer's [weak self] closure won't reference us
        // again.
        canonicalPollTimer?.invalidate()
        canonicalPollTimer = nil

        // Realtime teardown. Async work (channel removal) gets fired
        // into a fresh Task that captures the necessary refs
        // synchronously — deinit can't await, but the runtime keeps
        // the captured values alive until the Task finishes. The
        // listener tasks self-exit when their AsyncSequence streams
        // close after channel removal.
        let channel       = gamesRealtimeChannel
        let insertTask    = gamesInsertListenerTask
        let updateTask    = gamesUpdateListenerTask
        let watcherTask   = gamesWatcherTask
        let client        = SupabaseClientProvider.shared.client
        gamesRealtimeChannel    = nil
        gamesInsertListenerTask = nil
        gamesUpdateListenerTask = nil
        gamesWatcherTask        = nil
        gamesSubscribed         = false
        Task { @MainActor in
            insertTask?.cancel()
            updateTask?.cancel()
            watcherTask?.cancel()
            if let channel, let client {
                await client.realtimeV2.removeChannel(channel)
            }
        }
    }

    /// Fetches canonical live games and maps to LiveGame. Returns nil
    /// on error so the caller can log + decide to fall back; returns
    /// an array (possibly empty) on success.
    private func fetchCanonicalLiveGames() async -> [LiveGame]? {
        do {
            let canonical = try await SportsGameService.shared.fetchLiveGames()
            let mapped = canonical.compactMap(SportsGameAdapter.liveGame(from:))
            if mapped.count != canonical.count {
                liveLogger.warning("⚠️ Skipped \(canonical.count - mapped.count) Supabase live game(s) — team UUID not found in TeamDatabase")
            }
            return mapped
        } catch {
            liveLogger.error("❌ SportsGameService.fetchLiveGames threw — \(error)")
            return nil
        }
    }

    /// Fetches canonical upcoming games and maps to UpcomingGame.
    /// Same nil-on-error contract as `fetchCanonicalLiveGames`.
    private func fetchCanonicalUpcomingGames() async -> [UpcomingGame]? {
        do {
            let canonical = try await SportsGameService.shared.fetchUpcomingGames()
            let mapped = canonical.compactMap(SportsGameAdapter.upcomingGame(from:))
            if mapped.count != canonical.count {
                liveLogger.warning("⚠️ Skipped \(canonical.count - mapped.count) Supabase upcoming game(s) — team UUID or league not resolvable")
            }
            return mapped
        } catch {
            liveLogger.error("❌ SportsGameService.fetchUpcomingGames threw — \(error)")
            return nil
        }
    }

    // (Sports.Game → legacy UI model mapping lives in
    // SportsGameAdapter.swift — pure value transforms, isolated
    // for testability and so the eventual UI rewrite can drop the
    // adapter without touching this file.)

    // MARK: - Helpers

    func refresh() async {
        // Pull-to-refresh hits both data sources: the mock provider
        // (always — cheap) and the canonical Supabase load (re-tries
        // the bridge in case earlier fetches failed).
        await LiveScoreService.shared.refreshNow()
        await loadGames()
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
