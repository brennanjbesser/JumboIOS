import SwiftUI
import Combine
import OSLog

private let logger = Logger(subsystem: "com.jumbo", category: "chat")

struct TeamPageView: View {
    let team: SportsTeam
    @StateObject private var viewModel: TeamPageViewModel
    @State private var showingComposer = false
    @State private var selectedPost: Post?
    @State private var showingReportSheet = false
    @State private var postToReport: Post?
    @State private var refreshRotation: Double = 0

    init(team: SportsTeam) {
        self.team = team
        self._viewModel = StateObject(wrappedValue: TeamPageViewModel(team: team))
    }

    var body: some View {
        ZStack {
            // Dark background
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            NoiseBackground()
                .opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Team header — expands to include the live scoreboard when active
                teamHeaderSection

                // Sort options
                sortPicker

                // Posts
                if viewModel.isLoading && viewModel.posts.isEmpty {
                    loadingView
                } else if viewModel.posts.isEmpty {
                    emptyView
                } else {
                    postsList
                }
            }

            // FAB
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    newPostButton
                }
            }
        }
        .transientErrorBanner(viewModel.transientError)
        .navigationTitle(team.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    withAnimation(.linear(duration: 0.5)) {
                        refreshRotation += 360
                    }
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(team.primaryColor)
                        .rotationEffect(.degrees(refreshRotation))
                }
            }
        }
        .navigationDestination(item: $selectedPost) { post in
            CasinoThreadView(parentPost: post)
        }
        .sheet(isPresented: $showingComposer) {
            CasinoQuickComposeView(team: team) { content in
                Task {
                    let succeeded = await viewModel.createPost(content: content)
                    if !succeeded {
                        print("⚠️ TeamPage post send failed — draft was lost (modal already dismissed)")
                    }
                }
            }
            .presentationBackground(FanChatTheme.backgroundPrimary)
        }
        .sheet(isPresented: $showingReportSheet) {
            if let post = postToReport {
                CasinoReportSheet(post: post) { reason, additionalInfo in
                    Task {
                        await viewModel.reportPost(post, reason: reason, additionalInfo: additionalInfo)
                    }
                }
            }
        }
        .task {
            await viewModel.loadPosts()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Team Header Section
    //
    // Unified header that expands to include the live scoreboard when a game
    // is active. Identity row and scoreboard share one background, one set of
    // gradients, and one outer container — no card-on-card stacking.

    /// Team header section — composes the shared `RoomHeaderView`
    /// with an optional `CasinoTeamLiveGameBanner` underneath when
    /// a game is active. Both pieces share one outer container via
    /// `.roomHeaderContainer(accentColor:)` so they visually sit on
    /// the same canvas.
    private var teamHeaderSection: some View {
        VStack(spacing: 0) {
            RoomHeaderView(
                title: team.name,
                badge: RoomHeaderBadge(
                    text: team.league.displayName,
                    background: team.primaryColor
                ),
                icon: {
                    RoomHeaderIcon(
                        fill: LinearGradient(
                            colors: [team.primaryColor, team.secondaryColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        emoji: team.logoEmoji
                    )
                },
                secondaryContent: {
                    // Plain league name today; trivial to grow into
                    // "● Live · 7:42 Q3 · NFL" or similar Phase-5
                    // mixed-content lines without touching the
                    // component.
                    Text(team.league.displayName)
                }
            )

            if let game = viewModel.liveGame {
                CasinoTeamLiveGameBanner(game: game, team: team)
                    .padding(.top, 6)
            }
        }
        .roomHeaderContainer(accentColor: team.primaryColor)
    }

    // MARK: - Sort Picker
    private var sortPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FeedSortOption.allCases, id: \.self) { option in
                    Button {
                        withAnimation(AnimationConfig.snappy) {
                            viewModel.sortOption = option
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.icon)
                                .font(.system(size: 12, weight: .semibold))
                            Text(option.rawValue)
                                .font(.system(size: 13, weight: .bold))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(viewModel.sortOption == option ?
                                      AnyShapeStyle(LinearGradient(colors: [team.primaryColor, team.secondaryColor], startPoint: .leading, endPoint: .trailing)) :
                                      AnyShapeStyle(FanChatTheme.backgroundTertiary))
                        )
                        .foregroundColor(viewModel.sortOption == option ? .white : FanChatTheme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Posts List
    private var postsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {


                ForEach(Array(viewModel.posts.enumerated()), id: \.element.id) { index, post in
                    CasinoPostCard(
                        post: post,
                        team: team,
                        userVote: viewModel.getUserVote(for: post.id),
                        onUpvote: {
                            Task { await viewModel.vote(on: post, type: .upvote) }
                        },
                        onDownvote: {
                            Task { await viewModel.vote(on: post, type: .downvote) }
                        },
                        onReply: {
                            selectedPost = post
                        },
                        onReport: {
                            postToReport = post
                            showingReportSheet = true
                        },
                        onBlock: {
                            Task { await viewModel.blockUser(post.authorId) }
                        },
                        onDelete: viewModel.service.currentUser.isAdmin ? {
                            Task { await viewModel.deletePost(post) }
                        } : nil,
                        isAdmin: viewModel.service.currentUser.isAdmin
                    )
                    // Initial-load stagger (existing behavior).
                    .slideIn(delay: Double(index) * 0.05)
                    // Live-arrival transition. See
                    // GameRoomPlaceholderView for the full rationale —
                    // only fires for posts inserted under
                    // `withAnimation { … }` in the VM's .newPost
                    // notification handler.
                    .transition(
                        .opacity.combined(with: .move(edge: .bottom))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .refreshable {
            await viewModel.refresh()
        }
    }

    // MARK: - New Post Button
    private var newPostButton: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
            showingComposer = true
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [team.primaryColor, team.secondaryColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)

                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            CasinoSpinner()

            Text("Loading posts...")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(FanChatTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ScrollView {
            ChatStarterPrompts()
                .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Casino Team Live Game Banner
//
// Chrome-less scoreboard row. Lives inside `teamHeaderSection` so the parent
// supplies background, gradients, and outer padding — there's no card chrome
// here, just the scores + LIVE indicator content.

struct CasinoTeamLiveGameBanner: View {
    let game: LiveGame
    let team: SportsTeam

    private var awayColor: Color { game.awayTeam.primaryColor }
    private var homeColor: Color { game.homeTeam.primaryColor }
    private var awayIsMyTeam: Bool { game.awayTeam.id == team.id }
    private var homeIsMyTeam: Bool { game.homeTeam.id == team.id }

    var body: some View {
        HStack(spacing: 0) {
            teamSide(
                team: game.awayTeam,
                score: game.awayScore,
                accent: awayColor,
                isMyTeam: awayIsMyTeam,
                isAway: true
            )

            centerStatus
                .frame(width: 86)

            teamSide(
                team: game.homeTeam,
                score: game.homeScore,
                accent: homeColor,
                isMyTeam: homeIsMyTeam,
                isAway: false
            )
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Team side (center-clustered)
    //
    // Each side hugs the center status: away cluster sits on the right edge of
    // its slot (adjacent to LIVE), home cluster on the left edge. Badges land
    // on the outside, scores + name labels sit on the inside next to the
    // center column — the whole row reads as one tight unit.

    private func teamSide(
        team: SportsTeam,
        score: Int,
        accent: Color,
        isMyTeam: Bool,
        isAway: Bool
    ) -> some View {
        let inner: HorizontalAlignment = isAway ? .trailing : .leading

        return VStack(alignment: inner, spacing: 2) {
            HStack(spacing: 8) {
                if isAway {
                    teamBadge(team, accent: accent, isMyTeam: isMyTeam)
                    scoreText(score, accent: accent, isMyTeam: isMyTeam)
                } else {
                    scoreText(score, accent: accent, isMyTeam: isMyTeam)
                    teamBadge(team, accent: accent, isMyTeam: isMyTeam)
                }
            }

            Text(team.shortName)
                .font(.system(size: 10, weight: .black))
                .tracking(0.8)
                .foregroundColor(isMyTeam ? FanChatTheme.textPrimary : FanChatTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: isAway ? .trailing : .leading)
    }

    private func teamBadge(_ t: SportsTeam, accent: Color, isMyTeam: Bool) -> some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [t.primaryColor, t.secondaryColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                )

            Text(t.logoEmoji)
                .font(.system(size: 16))
        }
        .shadow(color: accent.opacity(isMyTeam ? 0.75 : 0.45), radius: isMyTeam ? 7 : 4)
        .shadow(color: accent.opacity(isMyTeam ? 0.40 : 0.25), radius: isMyTeam ? 12 : 8)
    }

    private func scoreText(_ score: Int, accent: Color, isMyTeam: Bool) -> some View {
        Text("\(score)")
            .font(.system(size: 32, weight: .black, design: .monospaced))
            .foregroundColor(FanChatTheme.textPrimary)
            .shadow(color: accent.opacity(isMyTeam ? 0.95 : 0.65), radius: isMyTeam ? 7 : 4)
            .shadow(color: accent.opacity(isMyTeam ? 0.55 : 0.35), radius: isMyTeam ? 13 : 9)
            .shadow(color: accent.opacity(isMyTeam ? 0.25 : 0.15), radius: isMyTeam ? 19 : 14)
    }

    // MARK: - Center status (compact)

    private var centerStatus: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                LivePulseIndicator(color: FanChatTheme.liveIndicator, animated: true)
                Text("LIVE")
                    .font(.system(size: 10, weight: .black))
                    .tracking(1.4)
                    .foregroundColor(FanChatTheme.liveIndicator)
                    .glow(FanChatTheme.liveIndicator, radius: 5)
            }

            if game.status == .halftime {
                Text("HALF")
                    .font(.system(size: 12, weight: .black))
                    .tracking(1.0)
                    .foregroundColor(FanChatTheme.textPrimary)
                    .shadow(color: FanChatTheme.liveIndicator.opacity(0.5), radius: 5)
            } else {
                if !game.timeRemaining.isEmpty {
                    Text(game.timeRemaining)
                        .font(.system(size: 13, weight: .black, design: .monospaced))
                        .foregroundColor(FanChatTheme.textPrimary)
                        .shadow(color: FanChatTheme.liveIndicator.opacity(0.55), radius: 5)
                }

                Text(game.period)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(FanChatTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

}

// MARK: - Casino Quick Compose View (for single team)
struct CasinoQuickComposeView: View {
    let team: SportsTeam
    let onPost: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isPosting = false
    @State private var isBoostEnabled = false
    @State private var boostSeconds: Double = 5
    @FocusState private var isFocused: Bool

    private let maxCharacters = 280

    var body: some View {
        NavigationStack {
            ZStack {
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                NoiseBackground()
                    .opacity(0.3)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Team header
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [team.primaryColor, team.secondaryColor],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 44, height: 44)

                            Text(team.logoEmoji)
                                .font(.system(size: 22))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("POSTING TO")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(1)
                            Text(team.fullName)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(FanChatTheme.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)

                    // Quick-post chips — populate the field, do not submit
                    QuickPostChipsRail { picked in
                        content = picked
                        isFocused = true
                    }
                    .padding(.bottom, 8)

                    Rectangle()
                        .fill(FanChatTheme.backgroundTertiary)
                        .frame(height: 1)

                    // Text editor
                    ZStack(alignment: .topLeading) {
                        if content.isEmpty {
                            Text("What's happening with \(team.shortName)?")
                                .font(.system(size: 18))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .padding(.top, 24)
                                .padding(.leading, 20)
                        }

                        TextEditor(text: $content)
                            .font(.system(size: 18))
                            .foregroundColor(FanChatTheme.textPrimary)
                            .padding(16)
                            .focused($isFocused)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                    }

                    // Glowing divider
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, FanChatTheme.backgroundTertiary, .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)

                    // Character count
                    HStack(spacing: 0) {
                        Spacer()
                        Text("\(content.count)")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(characterCountColor)
                            .glow(characterCountColor, radius: content.count > maxCharacters - 20 ? 4 : 0)
                        Text("/\(maxCharacters)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(FanChatTheme.textTertiary)
                    }
                    .padding(16)

                    // Boost section
                    BoostSection(isBoostEnabled: $isBoostEnabled, boostSeconds: $boostSeconds)
                        .padding(.horizontal, 16)

                    Spacer()
                }
            }
            .navigationTitle("New Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(FanChatTheme.textSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                        isPosting = true
                        onPost(content.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    } label: {
                        Text("Post")
                    }
                    .foregroundColor(canPost ? FanChatTheme.textSecondary : FanChatTheme.textTertiary)
                    .disabled(!canPost || isPosting)
                }
            }
            .onAppear {
                isFocused = true
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FanChatTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
    }

    private var canPost: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.count <= maxCharacters && !isPosting
    }

    private var characterCountColor: Color {
        if content.count > maxCharacters {
            return FanChatTheme.neonRed
        } else if content.count > maxCharacters - 20 {
            return FanChatTheme.neonOrange
        }
        return FanChatTheme.textTertiary
    }
}

// MARK: - Team Page View Model
//
// NOTE: Posts in this view model come from `MockChatService` while we wait
// for the real backend. We do NOT seed any fake user posts here — the empty
// room shows starter prompts (see `ChatStarterPrompts`) until the first real
// post arrives. Real chat will flow through this view model once the chat
// backend is wired in.

@MainActor
class TeamPageViewModel: ObservableObject {
    let team: SportsTeam
    // Resolved via the controlled-rollout accessor so this screen uses
    // RemoteChatService while the rest of the app stays on the mock.
    let service: any ChatServiceProtocol = AppServices.shared.chatServiceForChatScreens()

    @Published var posts: [Post] = []
    @Published var liveGame: LiveGame?
    @Published var sortOption: FeedSortOption = .hot {
        didSet {
            Task { await loadPosts() }
        }
    }
    @Published var isLoading = false
    @Published var newPostsCount = 0

    private var cancellables = Set<AnyCancellable>()
    private var pendingPosts: [Post] = []

    /// Posts whose vote/removeVote round-trip is currently in flight —
    /// see GameRoomViewModel for the rationale.
    private var inFlightVoteIds: Set<UUID> = []

    /// Anti-spam: rejects vote taps within 300ms of the previous —
    /// see GameRoomViewModel.
    private var lastVoteTime: Date = .distantPast

    /// Transient error toast — see GameRoomViewModel.transientError.
    @Published var transientError: String?
    private var transientErrorClearTask: Task<Void, Never>?

    private func showTransientError(_ message: String) {
        transientError = message
        transientErrorClearTask?.cancel()
        transientErrorClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.transientError = nil
        }
    }

    init(team: SportsTeam) {
        self.team = team
        self.room = .team(team.id)

        service.notificationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleNotification(notification)
            }
            .store(in: &cancellables)

        // Drive the team scoreboard from LiveScoreService. The banner is only
        // shown for genuinely active games (live or halftime); scheduled and
        // final games map to nil so the banner disappears automatically when
        // the game ends or before kickoff.
        LiveScoreService.shared.liveGamePublisher(for: team)
            .map { game -> LiveGame? in
                guard let game, game.status.isActive else { return nil }
                return game
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$liveGame)

        // Subscribe to realtime post inserts for THIS team's room. Server
        // filter `room_id=eq.<uuid>` cleanly isolates this team chat from
        // any game chat that happens to involve the same team.
        let subscriptionService = service
        let scopeRoom = room
        let teamShortName = team.shortName
        logger.debug("👥 TeamPageViewModel.init: team \(teamShortName) → subscribing room=\(scopeRoom.roomType):\(scopeRoom.roomId.uuidString)")
        Task { @MainActor in
            await subscriptionService.subscribeToPosts(room: scopeRoom)
        }
    }

    /// Stable room identity captured at init so deinit can tear down the
    /// matching scope without reading @MainActor state.
    let room: ChatRoom

    deinit {
        let subscriptionService = service
        let scopeRoom = room
        Task { @MainActor in
            await subscriptionService.unsubscribeFromPostScope(room: scopeRoom)
        }
    }

    func loadPosts() async {
        isLoading = true
        do {
            posts = try await service.fetchPostsForRoom(room, sortBy: sortOption)
        } catch {
            logger.error("Error loading posts: \(error)")
        }
        isLoading = false
    }

    func refresh() async {
        newPostsCount = 0
        pendingPosts = []
        await loadPosts()
    }

    /// Returns `true` on accepted send, `false` on empty-content bail
    /// or network failure. Mirrors createReply's contract.
    @discardableResult
    func createPost(content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try await service.createPost(content: trimmed, room: room, parentId: nil)
            return true
        } catch {
            logger.error("Error creating post: \(error)")
            showTransientError("Couldn't send. Try again.")
            return false
        }
    }

    func vote(on post: Post, type: VoteType) async {
        if Date().timeIntervalSince(lastVoteTime) < 0.3 {
            return
        }
        lastVoteTime = Date()

        guard !inFlightVoteIds.contains(post.id) else { return }
        inFlightVoteIds.insert(post.id)
        defer { inFlightVoteIds.remove(post.id) }

        do {
            let currentVote = service.getUserVote(for: post.id)
            if currentVote == type {
                _ = try await service.removeVote(from: post.id)
            } else {
                _ = try await service.vote(on: post.id, type: type)
            }
            if let index = posts.firstIndex(where: { $0.id == post.id }),
               let updatedPost = service.getPost(by: post.id) {
                posts[index] = updatedPost
                // Originating-device re-sort — see GameRoomViewModel.vote
                // for the rationale.
                posts = posts.sortedByFeed(sortOption)
            }
        } catch {
            logger.error("Error voting: \(error)")
            showTransientError("Vote failed. Try again.")
        }
    }

    func getUserVote(for postId: UUID) -> VoteType? {
        service.getUserVote(for: postId)
    }

    func reportPost(_ post: Post, reason: ReportReason, additionalInfo: String?) async {
        do {
            try await service.reportPost(post.id, reason: reason, additionalInfo: additionalInfo)
        } catch {
            logger.error("Error reporting: \(error)")
        }
    }

    func blockUser(_ userId: UUID) async {
        do {
            try await service.blockUser(userId)
            posts.removeAll { $0.authorId == userId }
        } catch {
            logger.error("Error blocking: \(error)")
        }
    }

    func deletePost(_ post: Post) async {
        do {
            try await service.deletePost(post.id)
            posts.removeAll { $0.id == post.id }
        } catch {
            logger.error("Error deleting: \(error)")
        }
    }

    func showNewPosts() {
        posts.insert(contentsOf: pendingPosts, at: 0)
        pendingPosts = []
        newPostsCount = 0
    }

    /// Realtime delta handler. The Supabase RPC `get_room_posts` is the
    /// canonical source of feed order; after a delta we re-apply the
    /// matching client-side sort so the order stays consistent with what
    /// a fresh fetch would return.
    private func handleNotification(_ notification: ChatNotification) {
        switch notification {
        case .newPost(let post):
            // Filter by room membership — keeps game posts out of the
            // team chat even when this team plays in the game.
            guard post.parentId == nil, post.belongs(to: room) else { return }
            if !posts.contains(where: { $0.id == post.id }) {
                // Wrapped in withAnimation so the per-card transition
                // fires for live arrivals only. See
                // GameRoomViewModel.handleNotification for rationale.
                withAnimation(AnimationConfig.snappy) {
                    posts.append(post)
                    posts = posts.sortedByFeed(sortOption)
                }
            }

        case .postUpdated(let post):
            // No withAnimation — vote / reply-count updates stay
            // silent per spec.
            if let index = posts.firstIndex(where: { $0.id == post.id }) {
                posts[index] = post
                posts = posts.sortedByFeed(sortOption)
            }

        case .postDeleted(let postId):
            posts.removeAll { $0.id == postId }

        case .scoreUpdate:
            // liveGame is now driven by LiveScoreService.liveGamePublisher(for:)
            break
        }
    }
}

#Preview {
    NavigationStack {
        TeamPageView(team: TeamDatabase.nflTeams.first!)
    }
}
