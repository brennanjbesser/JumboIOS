import SwiftUI
import Combine

struct FeedView: View {
    @StateObject private var viewModel = FeedViewModel()
    @ObservedObject var preferences = UserPreferences.shared
    @State private var showingComposer = false
    @State private var selectedPost: Post?
    @State private var showingReportSheet = false
    @State private var postToReport: Post?
    @State private var refreshRotation: Double = 0

    var body: some View {
        NavigationStack {
            ZStack {
                // Dark background with subtle texture
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                // Noise texture overlay
                NoiseBackground()
                    .opacity(0.3)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Live games banner (if any)
                    if !viewModel.liveGames.isEmpty {
                        liveGamesBanner
                    }

                    // Sort options
                    sortPicker

                    // Posts list
                    if viewModel.isLoading && viewModel.posts.isEmpty {
                        loadingView
                    } else if viewModel.posts.isEmpty {
                        emptyView
                    } else {
                        postsList
                    }
                }

                // FAB for new post
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        newPostButton
                    }
                }
            }
            .navigationTitle("JUMBO")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if viewModel.service.currentUser.isAdmin {
                        NavigationLink {
                            AdminView()
                        } label: {
                            Image(systemName: "shield.fill")
                                .foregroundColor(FanChatTheme.neonOrange)
                                .glow(FanChatTheme.neonOrange, radius: 4)
                        }
                    }
                }

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
                            .foregroundColor(FanChatTheme.neonCyan)
                            .rotationEffect(.degrees(refreshRotation))
                    }
                }
            }
            .navigationDestination(item: $selectedPost) { post in
                CasinoThreadView(parentPost: post)
            }
            .sheet(isPresented: $showingComposer) {
                CasinoComposeView(preferences: preferences) { content, teamId in
                    Task {
                        let succeeded = await viewModel.createPost(content: content, teamId: teamId)
                        if !succeeded {
                            print("⚠️ Feed post send failed — draft was lost (modal already dismissed)")
                        }
                    }
                }
                .presentationBackground(.ultraThinMaterial)
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
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") { }
            } message: {
                Text(viewModel.errorMessage ?? "Something went wrong")
            }
            .task {
                await viewModel.loadPosts(forTeamIds: preferences.followedTeamIds)
            }
            .refreshable {
                await viewModel.refresh()
            }
            .onChange(of: preferences.followedTeamIds) { _, newValue in
                Task {
                    await viewModel.loadPosts(forTeamIds: newValue)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Live Games Banner
    private var liveGamesBanner: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(viewModel.liveGames) { game in
                    CasinoLiveGameCard(game: game)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(
            FanChatTheme.backgroundSecondary
                .overlay(
                    LinearGradient(
                        colors: [FanChatTheme.neonRed.opacity(0.1), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
    }

    // MARK: - Sort Picker with distinct colors per option
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
                                      filterGradient(for: option) :
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

    // Helper functions for filter colors
    private func filterColor(for option: FeedSortOption) -> Color {
        switch option {
        case .hot: return FanChatTheme.filterHot
        case .new: return FanChatTheme.filterNew
        case .top: return FanChatTheme.filterTop
        }
    }

    private func filterGradient(for option: FeedSortOption) -> AnyShapeStyle {
        switch option {
        case .hot:
            return AnyShapeStyle(LinearGradient(colors: [FanChatTheme.filterHot, FanChatTheme.neonPink], startPoint: .leading, endPoint: .trailing))
        case .new:
            return AnyShapeStyle(LinearGradient(colors: [FanChatTheme.filterNew, FanChatTheme.neonBlue.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
        case .top:
            return AnyShapeStyle(LinearGradient(colors: [FanChatTheme.filterTop, FanChatTheme.neonPink], startPoint: .leading, endPoint: .trailing))
        }
    }

    // MARK: - Posts List
    private var postsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(viewModel.posts.enumerated()), id: \.element.id) { index, post in
                    CasinoPostCard(
                        post: post,
                        team: viewModel.getTeam(for: post),
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
                    .slideIn(delay: Double(index) * 0.05)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - New Posts Button with shimmer effect (replaced pulse)
    // MARK: - New Post Button (FAB) - Orange/Red gradient
    private var newPostButton: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
            showingComposer = true
        } label: {
            ZStack {
                // Glow background - orange
                Circle()
                    .fill(FanChatTheme.neonOrange.opacity(0.3))
                    .frame(width: 72, height: 72)
                    .blur(radius: 10)

                // Main button - orange/pink gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
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

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 20) {
            CasinoSpinner()

            Text("Loading posts...")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(FanChatTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty View
    private var emptyView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(FanChatTheme.backgroundTertiary)
                    .frame(width: 100, height: 100)

                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 40))
                    .foregroundColor(FanChatTheme.neonCyan)
                    .glow(FanChatTheme.neonCyan, radius: 8)
            }

            Text("No posts yet")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(FanChatTheme.textPrimary)

            Text("Be the first to start the conversation!")
                .font(.system(size: 15))
                .foregroundColor(FanChatTheme.textSecondary)

            Button {
                showingComposer = true
            } label: {
                Text("Post Something")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .glow(FanChatTheme.neonOrange, radius: 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - New Posts Bubble with Shimmer (replaced pulse animation)
struct NewPostsBubble: View {
    let count: Int
    let onTap: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var shimmerPhase: CGFloat = 0

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                Text("\(count) new post\(count == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [FanChatTheme.neonCyan, FanChatTheme.neonPurple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .overlay(
                // Shimmer effect sweeping across
                GeometryReader { geometry in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white.opacity(0.35),
                                    .clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * 0.6)
                        .offset(x: shimmerPhase * (geometry.size.width * 1.6) - geometry.size.width * 0.3)
                }
                .mask(Capsule())
            )
            .scaleEffect(scale)
        }
        .onAppear {
            // Subtle scale pulse (1.0 to 1.03)
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                scale = 1.03
            }
            // Shimmer sweep animation
            withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }
}

// MARK: - Casino Live Game Card
struct CasinoLiveGameCard: View {
    let game: LiveGame
    @State private var isGlowing = false

    var body: some View {
        VStack(spacing: 10) {
            // Live badge with pulse
            HStack(spacing: 6) {
                LivePulseIndicator()

                Text("LIVE")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(FanChatTheme.liveIndicator)
                    .glow(FanChatTheme.liveIndicator, radius: 4)
            }

            // Teams and score
            HStack(spacing: 14) {
                VStack(spacing: 4) {
                    Text(game.awayTeam.logoEmoji)
                        .font(.system(size: 22))
                    Text(game.awayTeam.shortName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(FanChatTheme.textPrimary)
                    Text("\(game.awayScore)")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundColor(FanChatTheme.textPrimary)
                        .glow(FanChatTheme.neonCyan, radius: 4)
                }

                VStack(spacing: 4) {
                    Text(game.period)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(FanChatTheme.textTertiary)
                    Text(game.timeRemaining)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(FanChatTheme.textSecondary)
                }

                VStack(spacing: 4) {
                    Text(game.homeTeam.logoEmoji)
                        .font(.system(size: 22))
                    Text(game.homeTeam.shortName)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(FanChatTheme.textPrimary)
                    Text("\(game.homeScore)")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundColor(FanChatTheme.textPrimary)
                        .glow(FanChatTheme.neonCyan, radius: 4)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(FanChatTheme.cardGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(FanChatTheme.liveIndicator.opacity(isGlowing ? 0.6 : 0.2), lineWidth: 1)
        )
        .glow(FanChatTheme.liveIndicator, radius: isGlowing ? 8 : 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                isGlowing = true
            }
        }
    }
}

// MARK: - View Model
@MainActor
class FeedViewModel: ObservableObject {
    @Published var posts: [Post] = []
    @Published var liveGames: [LiveGame] = []
    @Published var sortOption: FeedSortOption = .hot {
        didSet {
            Task { await loadPosts(forTeamIds: currentTeamIds) }
        }
    }
    @Published var isLoading = false
    @Published var showError = false
    @Published var errorMessage: String?
    @Published var newPostsCount = 0

    // Backed by `AppServices.shared.chatService` — see AppServices.swift.
    let service: any ChatServiceProtocol = AppServices.shared.chatService
    private var cancellables = Set<AnyCancellable>()
    private var pendingPosts: [Post] = []
    private var currentTeamIds: Set<UUID> = []

    /// Posts whose vote/removeVote round-trip is currently in flight —
    /// see GameRoomViewModel for the rationale.
    private var inFlightVoteIds: Set<UUID> = []

    /// Anti-spam: rejects vote taps within 300ms of the previous —
    /// see GameRoomViewModel.
    private var lastVoteTime: Date = .distantPast

    init() {
        service.notificationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleNotification(notification)
            }
            .store(in: &cancellables)
    }

    func loadPosts(forTeamIds teamIds: Set<UUID>) async {
        currentTeamIds = teamIds
        isLoading = true

        do {
            posts = try await service.fetchPosts(forTeamIds: teamIds, sortBy: sortOption)
            liveGames = service.getLiveGames(for: teamIds)
        } catch {
            showError(error)
        }

        isLoading = false
    }

    func refresh() async {
        newPostsCount = 0
        pendingPosts = []
        await loadPosts(forTeamIds: currentTeamIds)
    }

    /// Returns `true` on accepted send, `false` on empty-content bail
    /// or network failure. Mirrors createReply's contract.
    @discardableResult
    func createPost(content: String, teamId: UUID) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try await service.createPost(content: trimmed, teamId: teamId)
            return true
        } catch {
            showError(error)
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
            showError(error)
        }
    }

    func getUserVote(for postId: UUID) -> VoteType? {
        service.getUserVote(for: postId)
    }

    func getTeam(for post: Post) -> SportsTeam? {
        guard let teamId = post.teamId else { return nil }
        return TeamDatabase.team(byId: teamId)
    }

    func reportPost(_ post: Post, reason: ReportReason, additionalInfo: String?) async {
        do {
            try await service.reportPost(post.id, reason: reason, additionalInfo: additionalInfo)
        } catch {
            showError(error)
        }
    }

    func blockUser(_ userId: UUID) async {
        do {
            try await service.blockUser(userId)
            posts.removeAll { $0.authorId == userId }
        } catch {
            showError(error)
        }
    }

    func deletePost(_ post: Post) async {
        do {
            try await service.deletePost(post.id)
            posts.removeAll { $0.id == post.id }
        } catch {
            showError(error)
        }
    }

    func showNewPosts() {
        posts.insert(contentsOf: pendingPosts, at: 0)
        pendingPosts = []
        newPostsCount = 0
    }

    /// Realtime delta handler. Re-sort after each delta so the order
    /// stays consistent with what a fresh fetch would return — same
    /// rationale as the per-room VMs (see GameRoomViewModel comment).
    private func handleNotification(_ notification: ChatNotification) {
        switch notification {
        case .newPost(let post):
            guard post.parentId == nil else { return }
            if let teamId = post.teamId, !currentTeamIds.contains(teamId) { return }

            if !posts.contains(where: { $0.id == post.id }) {
                posts.append(post)
                posts = posts.sortedByFeed(sortOption)
            }

        case .postUpdated(let post):
            if let index = posts.firstIndex(where: { $0.id == post.id }) {
                posts[index] = post
                posts = posts.sortedByFeed(sortOption)
            }

        case .postDeleted(let postId):
            posts.removeAll { $0.id == postId }

        case .scoreUpdate:
            liveGames = service.getLiveGames(for: currentTeamIds)
        }
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

#Preview {
    FeedView()
}
