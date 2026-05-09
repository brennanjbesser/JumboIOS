import Combine
import SwiftUI

// MARK: - LIVE page UI variant toggle
//
// Single switch that gates the LIVE page UI experiment. Flip back to
// `.current` to instantly restore the pre-experiment look. The toggle
// is read by every LIVE-page surface (sections, cards, filters, trending
// carousel, upcoming rows) — it never branches data flow, navigation,
// actions, or state. Scope is intentionally local to LiveGamesView.swift
// so the experiment can't leak into team pages, threads, or chat cards.
//
//   .current  → preserve original heavy-card LIVE page (rollback target)
//   .refined  → live-stream-style refined LIVE page (active experiment)
//
// To revert: change `.refined` to `.current` on the line below. No other
// edits required.
enum LivePageUIVariant {
    case current
    case refined
}

private let livePageUIVariant: LivePageUIVariant = .refined

private var liveRefined: Bool { livePageUIVariant == .refined }

struct LiveGamesView: View {
    @StateObject private var viewModel = LiveGamesViewModel()
    @ObservedObject var preferences = UserPreferences.shared
    @State private var selectedLeagueFilter: League? = nil // nil = All
    @State private var scrollOffset: CGFloat = 0
    @State private var selectedGame: LiveGame?
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    // Collapse progress: 0 = fully expanded, 1 = fully collapsed
    private var collapseProgress: CGFloat {
        min(max(scrollOffset / 60, 0), 1)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                NoiseBackground()
                    .opacity(0.3)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Collapsing header
                    headerSection
                        .safeAreaPadding(.top, 4)
                        .background(FanChatTheme.backgroundPrimary)
                        .zIndex(1)

                    // Scrollable content. Section order is now Trending →
                    // LIVE NOW → Your Teams → Coming Up in both variants.
                    // The refined variant only differs in vertical rhythm
                    // (tighter spacing/padding); ordering is identical.
                    ScrollView {
                        VStack(spacing: liveRefined ? 18 : 24) {
                            trendingRoomsSection

                            liveNowSection

                            if !preferences.followedTeams.isEmpty {
                                yourTeamsSection
                            }

                            upcomingGamesSection
                        }
                        .padding(.top, liveRefined ? 10 : 14)
                        .padding(.bottom, 40)
                        .background(
                            // Invisible offset tracker — kept out of VStack flow
                            GeometryReader { geo in
                                Color.clear
                                    .preference(key: ScrollOffsetKey.self, value: -geo.frame(in: .named("liveScroll")).origin.y)
                            }
                        )
                    }
                    .coordinateSpace(name: "liveScroll")
                    .onPreferenceChange(ScrollOffsetKey.self) { value in
                        scrollOffset = value
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable {
                        await viewModel.refresh()
                    }
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: Binding(
                get: { selectedGame != nil },
                set: { if !$0 { selectedGame = nil } }
            )) {
                if let game = selectedGame {
                    GameRoomView(game: game)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var titleFontSize: CGFloat {
        28 - (10 * collapseProgress)
    }

    private var expandedOpacity: Double {
        Double(1 - collapseProgress * 1.5)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4 * (1 - collapseProgress)) {
            HStack {
                HStack(spacing: 6) {
                    Image("JumboIconLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 32 + 11 * (1 - collapseProgress))
                        .offset(y: -8)

                    Image("JumboTextLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 32 + 11 * (1 - collapseProgress))
                }

                if collapseProgress > 0.5 {
                    HStack(spacing: 5) {
                        LivePulseIndicator(animated: false)

                        Text("\(viewModel.liveGames.count) live")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(FanChatTheme.liveIndicator)
                    }
                    .transition(.opacity)
                }

                Spacer()
            }

            if collapseProgress < 0.8 {
                Text("Join the action happening right now")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(FanChatTheme.textSecondary)
                    .opacity(expandedOpacity)

                // Search bar
                gameSearchBar
                    .opacity(expandedOpacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, collapseProgress > 0.5 ? 8 : 14)
        .padding(.bottom, 10 * (1 - collapseProgress))
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.85), value: collapseProgress)
    }

    private var gameSearchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(FanChatTheme.textTertiary)

            TextField("Search games or teams...", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundColor(FanChatTheme.textPrimary)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(FanChatTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
        )
        .padding(.top, 4)
    }

    // MARK: - Live Now

    private var filteredLiveGames: [LiveGame] {
        var games = viewModel.liveGames

        if let league = selectedLeagueFilter {
            games = games.filter { $0.homeTeam.league == league }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            games = games.filter { game in
                game.homeTeam.shortName.lowercased().contains(query) ||
                game.awayTeam.shortName.lowercased().contains(query) ||
                game.homeTeam.fullName.lowercased().contains(query) ||
                game.awayTeam.fullName.lowercased().contains(query)
            }
        }

        return games
    }

    private var filteredUpcomingGames: [UpcomingGame] {
        var games = viewModel.upcomingGames

        if let league = selectedLeagueFilter {
            games = games.filter { $0.league == league }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            games = games.filter { game in
                game.homeTeam.shortName.lowercased().contains(query) ||
                game.awayTeam.shortName.lowercased().contains(query) ||
                game.homeTeam.fullName.lowercased().contains(query) ||
                game.awayTeam.fullName.lowercased().contains(query)
            }
        }

        return games
    }

    private var liveNowSection: some View {
        VStack(alignment: .leading, spacing: liveRefined ? 8 : 10) {
            // Refined variant gives LIVE NOW the primary section header
            // weight so it reads as more dominant than TRENDING.
            sectionHeader(
                title: "LIVE NOW",
                color: FanChatTheme.liveIndicator,
                emphasis: liveRefined ? .primary : .standard
            )

            // League filter
            leagueFilter

            LazyVStack(spacing: liveRefined ? 8 : 12) {
                let accentColors: [Color] = [
                    FanChatTheme.neonGreen, FanChatTheme.neonCyan,
                    FanChatTheme.neonOrange, FanChatTheme.neonPurple,
                    FanChatTheme.neonPink, FanChatTheme.neonBlue
                ]
                ForEach(Array(filteredLiveGames.enumerated()), id: \.element.id) { index, game in
                    LiveGameCardExpanded(game: game, fanCount: viewModel.fanCount(for: game), formattedFanCount: viewModel.formattedFanCount(viewModel.fanCount(for: game)), pulseColor: accentColors[index % accentColors.count])
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isSearchFocused = false
                            selectedGame = game
                        }
                        .slideIn(delay: Double(index) * 0.08)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var leagueFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: liveRefined ? 8 : 10) {
                leagueChip(label: "All", icon: nil, isSelected: selectedLeagueFilter == nil) {
                    selectedGame = nil
                    selectedLeagueFilter = nil
                }

                ForEach(League.allCases) { league in
                    leagueChip(label: league.displayName, icon: league.icon, isSelected: selectedLeagueFilter == league) {
                        selectedGame = nil
                        selectedLeagueFilter = league
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func leagueChip(label: String, icon: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(AnimationConfig.snappy) { action() }
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        } label: {
            HStack(spacing: liveRefined ? 5 : 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: liveRefined ? 12 : 14, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: liveRefined ? 13 : 14, weight: liveRefined ? .semibold : .bold))
            }
            .foregroundColor(isSelected ? .white : FanChatTheme.textSecondary)
            .padding(.horizontal, liveRefined ? 12 : 16)
            .padding(.vertical, liveRefined ? 7 : 10)
            .background(
                Capsule()
                    .fill(isSelected ?
                          AnyShapeStyle(LinearGradient(colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink], startPoint: .leading, endPoint: .trailing)) :
                          AnyShapeStyle(FanChatTheme.backgroundSecondary))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : FanChatTheme.backgroundTertiary.opacity(liveRefined ? 0.6 : 1.0), lineWidth: liveRefined ? 0.5 : 1)
            )
        }
    }

    // MARK: - Trending Rooms (auto-scrolling carousel)

    private var trendingRoomsSection: some View {
        VStack(alignment: .leading, spacing: liveRefined ? 6 : 10) {
            // Refined variant: subordinate header weight (textTertiary,
            // smaller) so TRENDING reads as secondary to LIVE NOW.
            sectionHeader(
                title: "TRENDING",
                color: liveRefined ? FanChatTheme.textTertiary : FanChatTheme.liveIndicator,
                emphasis: liveRefined ? .subordinate : .standard
            )

            TrendingCarousel(rooms: viewModel.trendingRooms)
        }
    }

    // MARK: - Your Teams

    private var yourTeamsSection: some View {
        VStack(alignment: .leading, spacing: liveRefined ? 8 : 10) {
            sectionHeader(
                title: "YOUR TEAMS",
                color: FanChatTheme.neonCyan,
                emphasis: liveRefined ? .subordinate : .standard
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(preferences.followedTeams) { team in
                        NavigationLink {
                            TeamPageView(team: team)
                        } label: {
                            YourTeamPill(team: team, status: viewModel.teamStatus(for: team))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Upcoming Games

    @ViewBuilder
    private var upcomingGamesSection: some View {
        if !filteredUpcomingGames.isEmpty {
            VStack(alignment: .leading, spacing: liveRefined ? 6 : 10) {
                // Refined: COMING UP reads as secondary to LIVE NOW
                sectionHeader(
                    title: "COMING UP",
                    color: liveRefined ? FanChatTheme.textTertiary : FanChatTheme.liveIndicator,
                    emphasis: liveRefined ? .subordinate : .standard
                )

                VStack(spacing: liveRefined ? 6 : 12) {
                    ForEach(filteredUpcomingGames) { game in
                        UpcomingGameRow(
                            game: game,
                            isNotified: viewModel.notifiedGameIds.contains(game.id),
                            formattedTime: viewModel.formattedStartTime(game.startTime)
                        ) {
                            viewModel.toggleNotification(for: game.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Section Header
    //
    // `emphasis` controls weight only — it does not change the title or
    // color the caller passes in. Used by the refined variant to give
    // LIVE NOW a primary look (larger, white-ish) while making TRENDING
    // / COMING UP / YOUR TEAMS read as subordinate (smaller, dimmer).

    enum SectionHeaderEmphasis {
        case standard    // current pre-experiment look (11pt black)
        case primary     // refined: bigger, brighter — for LIVE NOW
        case subordinate // refined: dimmer — for trending / coming up
    }

    private func sectionHeader(title: String, color: Color, emphasis: SectionHeaderEmphasis = .standard) -> some View {
        let fontSize: CGFloat
        let weight: Font.Weight
        let tracking: CGFloat
        switch emphasis {
        case .standard:
            fontSize = 11; weight = .black; tracking = 2
        case .primary:
            fontSize = 13; weight = .black; tracking = 1.8
        case .subordinate:
            fontSize = 10; weight = .heavy; tracking = 1.6
        }

        return HStack(spacing: 6) {
            // Refined LIVE NOW gets a small pulse dot inline so the
            // primary section reads as actively live at a glance.
            if liveRefined && emphasis == .primary {
                LivePulseIndicator(color: color, animated: true)
                    .scaleEffect(0.7)
            }

            Text(title)
                .font(.system(size: fontSize, weight: weight))
                .foregroundColor(color)
                .tracking(tracking)
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Scroll Offset Preference Key

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Carousel Animator (CADisplayLink-driven)

class CarouselAnimator: NSObject, ObservableObject {
    @Published private(set) var xOffset: CGFloat = 16

    private var displayLink: CADisplayLink?
    private var paused = false
    private var lastTickTime: CFTimeInterval = 0
    var setWidth: CGFloat = 0
    private let speed: CGFloat = 22.0
    private var resumeTimer: Timer?

    // Momentum physics
    private var momentumVelocity: CGFloat = 0
    private var isDecelerating = false
    private let friction: CGFloat = 0.96        // per-frame decay (lower = faster stop)
    private let velocityThreshold: CGFloat = 2   // stop deceleration below this

    // Velocity tracking
    private var dragSamples: [(time: CFTimeInterval, delta: CGFloat)] = []

    func start() {
        guard displayLink == nil else { return }
        paused = false
        lastTickTime = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        resumeTimer?.invalidate()
        resumeTimer = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp

        // Momentum deceleration phase
        if isDecelerating {
            momentumVelocity *= friction
            xOffset += momentumVelocity / 60.0
            normalize()

            if abs(momentumVelocity) < velocityThreshold {
                isDecelerating = false
                momentumVelocity = 0
                // Resume auto-scroll after momentum settles
                scheduleResume()
            }
            return
        }

        guard !paused, setWidth > 0 else {
            lastTickTime = 0
            return
        }

        // Normal auto-scroll
        if lastTickTime == 0 { lastTickTime = now }
        let dt = min(now - lastTickTime, 1.0 / 30.0)
        lastTickTime = now
        xOffset -= CGFloat(dt) * speed
        normalize()
    }

    func dragBegan() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        paused = true
        isDecelerating = false
        momentumVelocity = 0
        dragSamples.removeAll()
    }

    func dragMoved(delta: CGFloat) {
        xOffset += delta
        normalize()
        // Track recent drag velocity samples
        let now = CACurrentMediaTime()
        dragSamples.append((time: now, delta: delta))
        // Keep only the last 100ms of samples
        dragSamples = dragSamples.filter { now - $0.time < 0.1 }
    }

    func dragEnded() {
        normalize()

        // Calculate release velocity from recent samples
        let now = CACurrentMediaTime()
        let recentSamples = dragSamples.filter { now - $0.time < 0.1 }
        let totalDelta = recentSamples.reduce(CGFloat(0)) { $0 + $1.delta }
        let timeSpan = recentSamples.isEmpty ? 1.0 :
            max(now - (recentSamples.first?.time ?? now), 1.0 / 60.0)
        let velocity = totalDelta / CGFloat(timeSpan)
        dragSamples.removeAll()

        // Apply momentum if flick was fast enough
        if abs(velocity) > 50 {
            // Clamp to a reasonable max velocity
            momentumVelocity = min(max(velocity, -2000), 2000)
            isDecelerating = true
            // paused stays true — momentum drives movement, not auto-scroll
        } else {
            // Slow drag, no momentum — just schedule resume
            scheduleResume()
        }
    }

    private func scheduleResume() {
        resumeTimer?.invalidate()
        resumeTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.paused = false
        }
    }

    private func normalize() {
        guard setWidth > 0 else { return }
        while xOffset <= -setWidth + 16 { xOffset += setWidth }
        while xOffset > 16 { xOffset -= setWidth }
    }

    deinit { stop() }
}

// MARK: - Trending Carousel (infinite auto-scroll + drag)

struct TrendingCarousel: View {
    let rooms: [TrendingRoom]

    @StateObject private var animator = CarouselAnimator()
    @State private var isDragging = false
    @State private var lastDragTranslation: CGFloat = 0
    @State private var selectedRoom: TrendingRoom?
    @State private var showRoom = false

    // Refined variant uses smaller cards so the carousel takes less
    // vertical real estate and reads as secondary to LIVE NOW. Refined
    // bumped another ~5% (151→159, 113→119) for additional prominence;
    // current variant left at its prior 168/137 per "apply only to
    // refined" rule. Spacing and corner radius held — rhythm and
    // shape stay identical to the previous step.
    private var cardWidth: CGFloat { liveRefined ? 159 : 168 }
    private var cardHeight: CGFloat { liveRefined ? 119 : 137 }
    private var spacing: CGFloat { liveRefined ? 8 : 10 }

    private var setWidth: CGFloat {
        CGFloat(rooms.count) * (cardWidth + spacing)
    }

    /// Badge indices computed once — no adjacent duplicates, circular-safe
    private var badgeIndices: [Int] {
        TrendingBadge.assign(for: rooms)
    }

    /// Triple the rooms for seamless looping, carrying each card's badge index
    private var loopedItems: [(key: String, room: TrendingRoom, badgeIndex: Int)] {
        let indices = badgeIndices
        return (0..<3).flatMap { copy in
            rooms.enumerated().map { (idx, room) in
                (key: "\(copy)_\(idx)", room: room, badgeIndex: indices.isEmpty ? 0 : indices[idx])
            }
        }
    }

    var body: some View {
        // GeometryReader contains the oversized HStack width so it
        // doesn't leak upward and blow out the parent VStack layout.
        GeometryReader { _ in
            HStack(spacing: spacing) {
                ForEach(loopedItems, id: \.key) { item in
                    TrendingRoomCard(room: item.room, badge: TrendingBadge.all[item.badgeIndex])
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isDragging else { return }
                            selectedRoom = item.room
                            showRoom = true
                        }
                }
            }
            .offset(x: animator.xOffset)
            .highPriorityGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            lastDragTranslation = 0
                            animator.dragBegan()
                        }
                        let delta = value.translation.width - lastDragTranslation
                        lastDragTranslation = value.translation.width
                        animator.dragMoved(delta: delta)
                    }
                    .onEnded { _ in
                        lastDragTranslation = 0
                        animator.dragEnded()
                        // Brief cooldown so a stray tap doesn't fire after drag release
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            isDragging = false
                        }
                    }
            )
        }
        .frame(height: cardHeight)
        .clipped()
        .contentShape(Rectangle())
        .navigationDestination(isPresented: $showRoom) {
            if let room = selectedRoom {
                TrendingRoomChatView(room: room)
            }
        }
        .onAppear {
            animator.setWidth = setWidth
            animator.start()
        }
        .onDisappear {
            animator.stop()
        }
    }
}

// MARK: - Live Game Scoreboard Row
//
// Pure scoreboard layout (away | center status | home). Used inside the home
// `LiveGameCardExpanded` and inside the team chat banner so both stay pixel-
// identical. Wraps no chrome — the caller owns the card background.

struct LiveGameScoreboardRow: View {
    let game: LiveGame
    /// Opt-in pulsing LIVE dot. Defaults to false to preserve the
    /// pre-experiment look on every other surface that renders this
    /// row (e.g., team-page banner).
    var liveAnimated: Bool = false
    /// When false, omits the LIVE dot entirely and renders only the
    /// static red "LIVE" text. Used by the refined LIVE-page card to
    /// keep list items motion-free per the motion-hierarchy rule.
    var showLiveDot: Bool = true

    private func teamBadge(_ team: SportsTeam) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [team.primaryColor, team.secondaryColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 36)

            Text(team.logoEmoji)
                .font(.system(size: 18))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Away: badge + score paired, name below
            VStack(spacing: 3) {
                HStack(spacing: 8) {
                    teamBadge(game.awayTeam)
                    Text("\(game.awayScore)")
                        .font(.system(size: 24, weight: .black, design: .monospaced))
                        .foregroundColor(FanChatTheme.textPrimary)
                }
                Text(game.awayTeam.shortName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)

            // Center: status
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    if showLiveDot {
                        LivePulseIndicator(animated: liveAnimated)
                    }
                    Text("LIVE")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(FanChatTheme.liveIndicator)
                }

                if game.status == .halftime {
                    Text("HALF")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(FanChatTheme.textPrimary)
                } else {
                    Text(game.period)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(FanChatTheme.textTertiary)

                    if !game.timeRemaining.isEmpty {
                        Text(game.timeRemaining)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(FanChatTheme.textPrimary)
                    }
                }
            }
            .frame(width: 72)

            // Home: score + badge paired, name below
            VStack(spacing: 3) {
                HStack(spacing: 8) {
                    Text("\(game.homeScore)")
                        .font(.system(size: 24, weight: .black, design: .monospaced))
                        .foregroundColor(FanChatTheme.textPrimary)
                    teamBadge(game.homeTeam)
                }
                Text(game.homeTeam.shortName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }
}

// MARK: - Live Game Card (Expanded)

struct LiveGameCardExpanded: View {
    let game: LiveGame
    let fanCount: Int
    let formattedFanCount: String
    let pulseColor: Color

    // Refined variant: flatter card. Lighter background, smaller corner
    // radius, hairline border, no shadow, and a pulsing LIVE dot in the
    // scoreboard for subtle live polish.
    private var cornerRadius: CGFloat { liveRefined ? 14 : 18 }

    var body: some View {
        VStack(spacing: 0) {
            // Refined variant strips motion off the list items: no
            // pulsing red LIVE dot — just static "LIVE" text.
            // (`liveAnimated` stays at its default false; the dot itself
            // is hidden via `showLiveDot: false`.)
            LiveGameScoreboardRow(
                game: game,
                liveAnimated: false,
                showLiveDot: !liveRefined
            )

            // Divider
            Rectangle()
                .fill(FanChatTheme.backgroundTertiary.opacity(liveRefined ? 0.6 : 1.0))
                .frame(height: liveRefined ? 0.5 : 1)
                .padding(.horizontal, 16)

            // Bottom bar: league + fans + join
            HStack(spacing: 0) {
                // League — refined drops the "league" subtitle and
                // shows only the abbreviation, bumped to 14pt bold
                // textSecondary so it lands at roughly the same visual
                // weight as the centered chat-count number and the
                // JOIN action on the right. Plain text, no capsule,
                // no stroke. `.current` keeps the original two-line
                // primary-then-tertiary VStack for faithful rollback.
                Group {
                    if liveRefined {
                        Text(game.homeTeam.league.displayName)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(FanChatTheme.textSecondary)
                    } else {
                        VStack(spacing: 1) {
                            Text(game.homeTeam.league.displayName)
                                .font(.system(size: 14, weight: .black))
                                .foregroundColor(FanChatTheme.textPrimary)
                            Text("league")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(FanChatTheme.textTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(FanChatTheme.backgroundTertiary.opacity(liveRefined ? 0.6 : 1.0))
                    .frame(width: liveRefined ? 0.5 : 1, height: 24)

                // Fans — chat-count indicator is the ONE list-item dot
                // that keeps motion. Refined variant uses the soft
                // ambient pulse (1.4s opacity-only breathe) so the card
                // feels alive without a hard ping. `.current` keeps the
                // original standard pulse to preserve baseline.
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        LivePulseIndicator(
                            color: pulseColor,
                            animated: true,
                            style: liveRefined ? .soft : .standard
                        )
                        Text(formattedFanCount)
                            .font(.system(size: 14, weight: .black, design: .monospaced))
                            .foregroundColor(FanChatTheme.textPrimary)
                    }
                    Text("chatting")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(FanChatTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)

                Rectangle()
                    .fill(FanChatTheme.backgroundTertiary.opacity(liveRefined ? 0.6 : 1.0))
                    .frame(width: liveRefined ? 0.5 : 1, height: 24)

                // Join CTA — refined: uppercase "JOIN" at 13pt bold +
                // 10pt bold chevron, textSecondary for confident
                // readability. No capsule, no fill, no stroke; the
                // 14/6 padding + .frame(maxWidth: .infinity) +
                // .contentShape preserve the original tap region.
                // `.current` keeps the original "Join" glass-pill for
                // faithful rollback.
                HStack(spacing: 4) {
                    Text(liveRefined ? "JOIN" : "Join")
                        .font(.system(
                            size: liveRefined ? 13 : 12,
                            weight: liveRefined ? .bold : .semibold
                        ))
                    Image(systemName: "chevron.right")
                        .font(.system(
                            size: liveRefined ? 10 : 8,
                            weight: liveRefined ? .bold : .semibold
                        ))
                }
                .foregroundColor(FanChatTheme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(liveRefined ? Color.clear : Color.white.opacity(0.08))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            liveRefined ? Color.clear : Color.white.opacity(0.15),
                            lineWidth: liveRefined ? 0 : 0.5
                        )
                )
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, liveRefined ? 6 : 8)
        }
        .background(
            // Refined: match the canonical notification card surface —
            // FanChatTheme.backgroundSecondary at full opacity, no
            // outer stroke. `.current` keeps the original cardGradient
            // + 1pt backgroundTertiary stroke for faithful rollback.
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(liveRefined
                      ? AnyShapeStyle(FanChatTheme.backgroundSecondary)
                      : AnyShapeStyle(FanChatTheme.cardGradient))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    liveRefined ? Color.clear : FanChatTheme.backgroundTertiary,
                    lineWidth: liveRefined ? 0 : 1
                )
        )
    }
}

// MARK: - Trending Room Card

// MARK: - Badge definitions (shared)

struct TrendingBadge {
    let label: String
    let icon: String

    static let all: [TrendingBadge] = [
        TrendingBadge(label: "HOT", icon: "flame.fill"),
        TrendingBadge(label: "LIVE", icon: "bolt.fill"),
        TrendingBadge(label: "BUZZING", icon: "waveform"),
        TrendingBadge(label: "POPULAR", icon: "star.fill"),
        TrendingBadge(label: "VIRAL", icon: "arrow.up.right"),
        TrendingBadge(label: "ON FIRE", icon: "flame.fill"),
    ]

    /// Assigns badges to an ordered list of rooms so no two adjacent cards share a label.
    /// Treats the list as circular (last→first also differ) for seamless looped carousels.
    static func assign(for rooms: [TrendingRoom]) -> [Int] {
        guard !rooms.isEmpty else { return [] }
        let count = all.count
        var result = [Int]()

        for (i, room) in rooms.enumerated() {
            var pick = abs(room.id.hashValue) % count
            // Avoid matching the previous card
            if i > 0 && pick == result[i - 1] {
                pick = (pick + 1) % count
            }
            result.append(pick)
        }

        // Circular fix: ensure last and first don't match (for looping carousel)
        if rooms.count > 1 && result.last == result.first {
            let last = result.count - 1
            result[last] = (result[last] + 1) % count
            // Also re-check it doesn't now match its own predecessor
            if result[last] == result[last - 1] {
                result[last] = (result[last] + 1) % count
            }
        }

        return result
    }
}

struct TrendingRoomCard: View {
    let room: TrendingRoom
    let badge: TrendingBadge

    private var formattedUsers: String {
        room.activeUsers >= 1000
            ? String(format: "%.1fk", Double(room.activeUsers) / 1000.0)
            : "\(room.activeUsers)"
    }

    // Refined variant: smaller card, lighter chrome — secondary to the
    // LIVE NOW stack. Numbers match TrendingCarousel.cardWidth/cardHeight
    // (must stay in sync — the carousel sizes its scroll math from
    // cardWidth/cardHeight, and a mismatch would clip or overflow).
    private var width: CGFloat { liveRefined ? 159 : 168 }
    private var height: CGFloat { liveRefined ? 119 : 137 }
    private var pad: CGFloat { liveRefined ? 11 : 14 }
    private var cornerRadius: CGFloat { liveRefined ? 14 : 18 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top: emoji + badge
            HStack(alignment: .top) {
                Text(room.emoji)
                    .font(.system(size: liveRefined ? 22 : 24))

                Spacer()

                HStack(spacing: 3) {
                    Image(systemName: badge.icon)
                        .font(.system(size: 7))
                    Text(badge.label)
                        .font(.system(size: 9, weight: .black))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(room.accentColor)
                        .overlay(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [.clear, Color.black.opacity(0.35)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                        )
                        .clipShape(Capsule())
                )
            }

            Spacer()

            // Title — refined gets +1pt to match the larger card
            // footprint (14 vs the prior 13). Current unchanged.
            Text(room.title)
                .font(.system(size: liveRefined ? 14 : 14, weight: .bold))
                .foregroundColor(FanChatTheme.textPrimary)
                .lineLimit(2)
                .padding(.bottom, liveRefined ? 4 : 5)

            // Active users — refined keeps the dot static (motion
            // hierarchy: list items stay still). `.current` keeps the
            // baseline animated dot.
            HStack(spacing: 4) {
                LivePulseIndicator(color: room.accentColor, animated: !liveRefined)

                Text("\(formattedUsers) active")
                    .font(.system(size: liveRefined ? 10 : 11, weight: .semibold))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
        }
        .padding(pad)
        .frame(width: width, height: height)
        .background(
            // Refined: notification card surface —
            // FanChatTheme.backgroundSecondary, no stroke. The room's
            // accent color is preserved INSIDE the card (badge fill,
            // pulse dot), so removing the edge accent stroke loses no
            // identity. `.current` keeps the original cardGradient +
            // accent stroke.
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(liveRefined
                      ? AnyShapeStyle(FanChatTheme.backgroundSecondary)
                      : AnyShapeStyle(FanChatTheme.cardGradient))
        )
        .overlay(
            // Refined: very subtle gradient hairline (0.5pt) that
            // weaves the room's accent into a glassy diagonal — adds
            // polish without reading as a glow. Top-leading carries a
            // hint of identity, bottom-trailing fades into a near-
            // invisible white wash. No animation, no glow.
            // `.current` keeps the original solid accent-tinted stroke
            // for faithful rollback.
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    liveRefined
                        ? AnyShapeStyle(LinearGradient(
                            colors: [
                                room.accentColor.opacity(0.22),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                          ))
                        : AnyShapeStyle(room.accentColor.opacity(0.2)),
                    lineWidth: liveRefined ? 0.5 : 1
                )
        )
    }
}

// MARK: - Your Team Pill

struct YourTeamPill: View {
    let team: SportsTeam
    let status: TeamLiveStatus

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if status == .liveNow {
                    Circle()
                        .fill(team.primaryColor.opacity(0.3))
                        .frame(width: 62, height: 62)
                        .blur(radius: 8)
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [team.primaryColor, team.secondaryColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)
                    .glow(team.primaryColor, radius: 6, isActive: status == .liveNow)

                Text(team.logoEmoji)
                    .font(.system(size: 26))
            }

            Text(team.shortName)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(FanChatTheme.textPrimary)

            Text(status.text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(status.color)
        }
        .frame(width: 80)
    }
}

// MARK: - Upcoming Game Row

struct UpcomingGameRow: View {
    let game: UpcomingGame
    let isNotified: Bool
    let formattedTime: String
    let onToggleNotify: () -> Void

    // Refined variant: flat row, secondary to live games — half the
    // vertical padding, lighter background, hairline border, smaller
    // corner radius.
    private var cornerRadius: CGFloat { liveRefined ? 10 : 16 }

    var body: some View {
        HStack(spacing: liveRefined ? 8 : 10) {
            // League pill — refined uses backgroundSecondary so the
            // pill stays distinct against the lifted backgroundTertiary
            // row (the row got bumped a tier lighter; the pill needs to
            // sit a tier darker to read).
            Text(game.league.displayName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(FanChatTheme.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(liveRefined
                              ? AnyShapeStyle(FanChatTheme.backgroundSecondary)
                              : AnyShapeStyle(FanChatTheme.backgroundTertiary))
                )

            // Away team — refined matchup text bumps from .bold to
            // .heavy for slightly stronger emphasis; size unchanged.
            HStack(spacing: 6) {
                Text(game.awayTeam.logoEmoji)
                    .font(.system(size: liveRefined ? 14 : 16))

                Text(game.awayTeam.shortName)
                    .font(.system(size: liveRefined ? 13 : 14, weight: liveRefined ? .heavy : .bold))
                    .foregroundColor(FanChatTheme.textPrimary)
            }

            Text("vs")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(FanChatTheme.textTertiary)

            // Home team
            HStack(spacing: 6) {
                Text(game.homeTeam.shortName)
                    .font(.system(size: liveRefined ? 13 : 14, weight: liveRefined ? .heavy : .bold))
                    .foregroundColor(FanChatTheme.textPrimary)

                Text(game.homeTeam.logoEmoji)
                    .font(.system(size: liveRefined ? 14 : 16))
            }

            Spacer()

            Text(formattedTime)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(FanChatTheme.textTertiary)

            Button {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                onToggleNotify()
            } label: {
                Image(systemName: isNotified ? "bell.fill" : "bell")
                    .font(.system(size: liveRefined ? 14 : 16))
                    .foregroundColor(isNotified ? FanChatTheme.neonOrange : FanChatTheme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, liveRefined ? 12 : 16)
        // Refined gets +3 vertical padding (10→13) for ~+6pt total row
        // height, hitting the lower bound of the requested +6–8pt.
        .padding(.vertical, liveRefined ? 13 : 19)
        .background(
            // Refined: lifted to FanChatTheme.backgroundTertiary for
            // stronger contrast against the dark page bg. Still lighter
            // than LIVE NOW cards (which sit at backgroundSecondary), so
            // the secondary-to-primary visual hierarchy holds: LIVE
            // cards read as the heavier surface, Coming Up reads as the
            // lifted-but-quieter strip.
            // `.current` keeps the original cardGradient for rollback.
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(liveRefined
                      ? AnyShapeStyle(FanChatTheme.backgroundTertiary)
                      : AnyShapeStyle(FanChatTheme.cardGradient))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    liveRefined ? Color.clear : FanChatTheme.backgroundTertiary,
                    lineWidth: liveRefined ? 0 : 1
                )
        )
    }
}

#Preview {
    LiveGamesView()
}
