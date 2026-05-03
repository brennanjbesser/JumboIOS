import SwiftUI
import Combine

// MARK: - Leaderboard Entry (derived from post activity)

struct LeaderboardEntry: Identifiable {
    let id: UUID // authorId
    let authorName: String
    let authorId: UUID
    let totalScore: Int      // sum of (upvotes - downvotes) across all posts
    let totalReplies: Int    // sum of reply counts
    let postCount: Int
    // Engagement: score points + reply points (replies weighted 2x)
    var engagementScore: Int { totalScore + (totalReplies * 2) }
}

// MARK: - Room Detail ViewModel

@MainActor
class MoneyRoomDetailViewModel: ObservableObject {
    let room: MoneyRoom
    // Backed by `AppServices.shared.chatService` — see AppServices.swift.
    let service: any ChatServiceProtocol = AppServices.shared.chatService

    @Published var posts: [Post] = []
    @Published var hasJoined = false
    @Published var isProcessingPayment = false
    @Published var timeRemaining: String = ""
    @Published var newPostsCount = 0
    @Published var sortOption: FeedSortOption = .new {
        didSet {
            Task { await loadPosts() }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var pendingPosts: [Post] = []
    private var countdownTimer: Timer?
    private let roomDuration: TimeInterval = 3600

    /// Posts whose vote/removeVote round-trip is currently in flight —
    /// see GameRoomViewModel for the rationale.
    private var inFlightVoteIds: Set<UUID> = []

    /// Anti-spam: rejects vote taps within 300ms of the previous —
    /// see GameRoomViewModel.
    private var lastVoteTime: Date = .distantPast

    // Use home team of first live game as a stable teamId for this room's posts
    private let roomTeamId: UUID

    init(room: MoneyRoom) {
        self.room = room
        let allTeams = TeamDatabase.allTeams
        let teamIndex = abs(room.id.hashValue) % allTeams.count
        self.roomTeamId = allTeams[teamIndex].id

        service.notificationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleNotification(notification)
            }
            .store(in: &cancellables)

        seedMockPosts()
        startCountdown()
    }

    deinit {
        countdownTimer?.invalidate()
    }

    // MARK: - Mock Posts

    private func seedMockPosts() {
        let now = Date()

        let mockPosts = [
            Post.preview(
                authorId: UUID(),
                content: "Chiefs win by 10, Mahomes throws for 300+ yards. Lock it in. 🔒",
                createdAt: now.addingTimeInterval(-300),
                upvotes: 14,
                downvotes: 3,
                replyCount: 3,
                teamId: roomTeamId
            ),
            Post.preview(
                authorId: UUID(),
                content: "Going with the underdog here. Ravens pull the upset 27-24.",
                createdAt: now.addingTimeInterval(-240),
                upvotes: 9,
                downvotes: 5,
                replyCount: 1,
                teamId: roomTeamId
            ),
            Post.preview(
                authorId: UUID(),
                content: "This one goes to OT. Final score 31-28, doesn't matter who wins it'll be close.",
                createdAt: now.addingTimeInterval(-180),
                upvotes: 21,
                downvotes: 2,
                replyCount: 4,
                teamId: roomTeamId
            ),
            Post.preview(
                authorId: UUID(),
                content: "Defense wins championships. Under 40 total points. Book it. 📖",
                createdAt: now.addingTimeInterval(-90),
                upvotes: 6,
                downvotes: 4,
                teamId: roomTeamId
            ),
        ]

        for post in mockPosts {
            service.injectPost(post)
        }
        posts = mockPosts
    }

    // MARK: - Load Posts

    func loadPosts() async {
        do {
            let fetched = try await service.fetchPostsForTeam(roomTeamId, sortBy: sortOption)
            posts = fetched
        } catch {
            print("Error loading room posts: \(error)")
        }
    }

    func refresh() async {
        newPostsCount = 0
        pendingPosts = []
        await loadPosts()
    }

    // MARK: - Join Room

    func joinRoom() async {
        isProcessingPayment = true
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        withAnimation(AnimationConfig.snappy) {
            isProcessingPayment = false
            hasJoined = true
        }
    }

    // MARK: - Create Post

    /// Returns `true` on accepted send, `false` on empty-content bail
    /// or network failure. Mirrors createReply's contract.
    @discardableResult
    func createPost(content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try await service.createPost(content: trimmed, teamId: roomTeamId)
            return true
        } catch {
            print("Error creating post: \(error)")
            return false
        }
    }

    // MARK: - Voting

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
            print("Error voting: \(error)")
        }
    }

    func getUserVote(for postId: UUID) -> VoteType? {
        service.getUserVote(for: postId)
    }

    // MARK: - Moderation

    func reportPost(_ post: Post, reason: ReportReason, additionalInfo: String?) async {
        do {
            try await service.reportPost(post.id, reason: reason, additionalInfo: additionalInfo)
        } catch {
            print("Error reporting: \(error)")
        }
    }

    func blockUser(_ userId: UUID) async {
        do {
            try await service.blockUser(userId)
            posts.removeAll { $0.authorId == userId }
        } catch {
            print("Error blocking: \(error)")
        }
    }

    func deletePost(_ post: Post) async {
        do {
            try await service.deletePost(post.id)
            posts.removeAll { $0.id == post.id }
        } catch {
            print("Error deleting: \(error)")
        }
    }

    // MARK: - New Posts

    func showNewPosts() {
        posts.insert(contentsOf: pendingPosts, at: 0)
        pendingPosts = []
        newPostsCount = 0
    }

    // MARK: - Leaderboard (derived from post activity)

    var leaderboard: [LeaderboardEntry] {
        var authorStats: [UUID: (name: String, score: Int, replies: Int, count: Int)] = [:]

        for post in posts {
            let existing = authorStats[post.authorId] ?? (name: post.anonymousName, score: 0, replies: 0, count: 0)
            authorStats[post.authorId] = (
                name: post.anonymousName,
                score: existing.score + post.score,
                replies: existing.replies + post.replyCount,
                count: existing.count + 1
            )
        }

        return authorStats.map { authorId, stats in
            LeaderboardEntry(
                id: authorId,
                authorName: stats.name,
                authorId: authorId,
                totalScore: stats.score,
                totalReplies: stats.replies,
                postCount: stats.count
            )
        }
        .sorted { $0.engagementScore > $1.engagementScore }
    }

    // MARK: - Notifications

    /// Realtime delta handler. Re-sort after each delta so the order
    /// stays consistent with what a fresh fetch would return — same
    /// rationale as the per-room VMs (see GameRoomViewModel comment).
    private func handleNotification(_ notification: ChatNotification) {
        switch notification {
        case .newPost(let post):
            guard post.parentId == nil else { return }
            guard post.teamId == roomTeamId else { return }
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
            break
        }
    }

    // MARK: - Countdown

    private func startCountdown() {
        updateTimeRemaining()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateTimeRemaining()
            }
        }
    }

    private func updateTimeRemaining() {
        let endTime = room.createdAt.addingTimeInterval(roomDuration)
        let remaining = endTime.timeIntervalSince(Date())

        if remaining <= 0 {
            timeRemaining = "Ended"
            countdownTimer?.invalidate()
            return
        }

        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60

        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            timeRemaining = String(format: "%d:%02d:%02d", hours, mins, seconds)
        } else {
            timeRemaining = String(format: "%d:%02d", minutes, seconds)
        }
    }
}

// MARK: - Room Detail View

struct MoneyRoomDetailView: View {
    let room: MoneyRoom
    @StateObject private var viewModel: MoneyRoomDetailViewModel
    @State private var showingComposer = false
    @State private var selectedPost: Post?
    @State private var showingReportSheet = false
    @State private var postToReport: Post?
    @State private var scrollOffset: CGFloat = 0

    private var headerCollapse: CGFloat {
        min(max(scrollOffset / 70, 0), 1)
    }

    private var isCollapsed: Bool {
        headerCollapse > 0.8
    }

    init(room: MoneyRoom) {
        self.room = room
        self._viewModel = StateObject(wrappedValue: MoneyRoomDetailViewModel(room: room))
    }

    var body: some View {
        ZStack {
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            NoiseBackground()
                .opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                roomHeader

                // Feed area — same pattern as team/game/trending chats
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Scroll offset tracker
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: MoneyScrollOffsetKey.self, value: -geo.frame(in: .named("moneyScroll")).origin.y)
                        }
                        .frame(height: 0)

                        ForEach(Array(viewModel.posts.enumerated()), id: \.element.id) { index, post in
                            CasinoPostCard(
                                post: post,
                                team: nil,
                                userVote: viewModel.getUserVote(for: post.id),
                                onUpvote: { Task { await viewModel.vote(on: post, type: .upvote) } },
                                onDownvote: { Task { await viewModel.vote(on: post, type: .downvote) } },
                                onReply: { selectedPost = post },
                                onReport: {
                                    postToReport = post
                                    showingReportSheet = true
                                },
                                onBlock: { Task { await viewModel.blockUser(post.authorId) } },
                                onDelete: viewModel.service.currentUser.isAdmin ? {
                                    Task { await viewModel.deletePost(post) }
                                } : nil,
                                isAdmin: viewModel.service.currentUser.isAdmin
                            )
                            .slideIn(delay: Double(index) * 0.05)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 100)
                }
                .scrollIndicators(.hidden)
                .coordinateSpace(name: "moneyScroll")
                .onPreferenceChange(MoneyScrollOffsetKey.self) { value in
                    scrollOffset = value
                }

                // Join bar (pinned at bottom, only before joining)
                if !viewModel.hasJoined {
                    joinBar
                }
            }

            // FAB — only visible after joining
            if viewModel.hasJoined {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        newPostButton
                    }
                }
            }
        }
        .navigationTitle(room.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationDestination(item: $selectedPost) { post in
            CasinoThreadView(parentPost: post)
        }
        .sheet(isPresented: $showingComposer) {
            MoneyRoomComposeView(room: room) { content in
                Task {
                    let succeeded = await viewModel.createPost(content: content)
                    if !succeeded {
                        print("⚠️ MoneyRoom post send failed — draft was lost (modal already dismissed)")
                    }
                }
            }
            .presentationBackground(FanChatTheme.backgroundPrimary)
        }
        .sheet(isPresented: $showingReportSheet) {
            if let post = postToReport {
                CasinoReportSheet(post: post) { reason, additionalInfo in
                    Task { await viewModel.reportPost(post, reason: reason, additionalInfo: additionalInfo) }
                }
            }
        }
        .task {
            await viewModel.loadPosts()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Room Header (collapsible)
    // Expanded: ~50pt compact bar + expanded content. Collapsed: ~50pt compact bar only.
    // Collapsed height: 50pt (30 circle + 10+10 padding). Expanded height: natural layout.

    private var compactBarHeight: CGFloat { 50 }

    private var roomHeader: some View {
        VStack(spacing: 0) {
            // Compact bar — always visible, fixed height
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(room.accentColor.opacity(0.15))
                        .frame(width: 30, height: 30)

                    Text(room.emoji)
                        .font(.system(size: 15))
                }

                Text(room.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(FanChatTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(formattedCurrency(livePrizePool))
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundColor(FanChatTheme.neonGreen)

                Text(viewModel.timeRemaining)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(viewModel.timeRemaining == "Ended" ? FanChatTheme.textTertiary : FanChatTheme.textPrimary)
            }
            .frame(height: compactBarHeight)
            .padding(.horizontal, 16)

            // Expandable section — height shrinks to 0 when collapsed
            expandedHeaderContent
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .frame(maxHeight: isCollapsed ? 0 : .infinity)
                .clipped()
                .opacity(isCollapsed ? 0 : 1)
        }
        .background(
            FanChatTheme.backgroundSecondary
                .overlay(
                    LinearGradient(
                        colors: [room.accentColor.opacity(0.08), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: isCollapsed)
    }

    // MARK: - Expanded Header Content

    private var expandedHeaderContent: some View {
        VStack(spacing: 14) {
            if !room.topic.isEmpty {
                Text(room.topic)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FanChatTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            headerStatsRow

            prizeLeaderboard
        }
        .opacity(Double(1 - headerCollapse * 1.3))
    }

    private var headerStatsRow: some View {
        HStack(spacing: 0) {
            VStack(spacing: 1) {
                Text(formattedCurrency(room.prizePool))
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundColor(FanChatTheme.neonGreen)
                Text("prize")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)

            Rectangle().fill(FanChatTheme.backgroundTertiary).frame(width: 1, height: 28)

            VStack(spacing: 1) {
                Text("\(room.participants)/\(room.maxParticipants)")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundColor(FanChatTheme.textPrimary)
                Text("players")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)

            Rectangle().fill(FanChatTheme.backgroundTertiary).frame(width: 1, height: 28)

            VStack(spacing: 1) {
                Text(formattedCurrency(room.entryFee))
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundColor(FanChatTheme.textPrimary)
                Text("entry")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)

            Rectangle().fill(FanChatTheme.backgroundTertiary).frame(width: 1, height: 28)

            VStack(spacing: 1) {
                Text("\(viewModel.posts.count)")
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundColor(FanChatTheme.textPrimary)
                Text("posts")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Prize + Leaderboard (unified)

    private var livePrizePool: Double {
        room.entryFee * Double(room.participants)
    }

    private var prizeLeaderboard: some View {
        let top3 = viewModel.leaderboard.prefix(3)
        let placements: [(medal: String, percent: Int, amount: Double, color: Color)] = [
            ("🥇", 50, livePrizePool * 0.5, FanChatTheme.neonYellow),
            ("🥈", 30, livePrizePool * 0.3, Color(white: 0.7)),
            ("🥉", 20, livePrizePool * 0.2, FanChatTheme.neonOrange),
        ]

        return VStack(spacing: 10) {
            HStack {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 11))
                    .foregroundColor(FanChatTheme.neonYellow)
                Text("PRIZES & STANDINGS")
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(FanChatTheme.textTertiary)
                    .tracking(1.5)

                Spacer()

                HStack(spacing: 2) {
                    Text(formattedCurrency(livePrizePool))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(FanChatTheme.neonGreen)
                    Text("pool")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(FanChatTheme.textTertiary)
                }
            }

            ForEach(Array(placements.enumerated()), id: \.offset) { index, placement in
                let leader = index < top3.count ? Array(top3)[index] : nil
                placementRow(
                    medal: placement.medal,
                    percent: placement.percent,
                    amount: placement.amount,
                    color: placement.color,
                    leader: leader
                )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FanChatTheme.backgroundPrimary.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(FanChatTheme.neonGreen.opacity(0.15), lineWidth: 1)
        )
    }

    // Expanded placement row
    private func placementRow(medal: String, percent: Int, amount: Double, color: Color, leader: LeaderboardEntry?) -> some View {
        HStack(spacing: 12) {
            Text(medal)
                .font(.system(size: 18))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(formattedCurrency(amount))
                    .font(.system(size: 16, weight: .black, design: .rounded))
                    .foregroundColor(color)
                Text("\(percent)% of pool")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(FanChatTheme.textTertiary)
            }

            Spacer()

            if let leader = leader {
                HStack(spacing: 8) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(leader.authorName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(FanChatTheme.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill")
                                .font(.system(size: 8))
                            Text("\(leader.engagementScore)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(color)
                    }

                    ZStack {
                        Circle()
                            .fill(FanChatTheme.backgroundTertiary)
                            .frame(width: 30, height: 30)

                        Text(AvatarEmojis.all[abs(leader.authorId.hashValue) % AvatarEmojis.all.count])
                            .font(.system(size: 15))
                    }
                }
            } else {
                Text("—")
                    .font(.system(size: 13))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    // MARK: - Join Bar (kept intact)

    private var joinBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(FanChatTheme.backgroundTertiary)
                .frame(height: 1)

            VStack(spacing: 10) {
                Text("Join this room to post your take")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(FanChatTheme.textSecondary)

                Button {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    Task { await viewModel.joinRoom() }
                } label: {
                    HStack(spacing: 8) {
                        if viewModel.isProcessingPayment {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                            Text("Processing...")
                                .font(.system(size: 15, weight: .bold))
                        } else {
                            Image(systemName: "lock.open.fill")
                                .font(.system(size: 14))
                            Text("Join for \(formattedCurrency(room.entryFee))")
                                .font(.system(size: 15, weight: .bold))
                        }
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(
                                LinearGradient(
                                    colors: [room.accentColor, room.accentColor.opacity(0.7)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                }
                .disabled(viewModel.isProcessingPayment || room.status == .closed)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(FanChatTheme.backgroundSecondary)
        }
    }

    // MARK: - FAB

    private var newPostButton: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
            showingComposer = true
        } label: {
            ZStack {
                Circle()
                    .fill(room.accentColor.opacity(0.3))
                    .frame(width: 72, height: 72)
                    .blur(radius: 10)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [room.accentColor, room.accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 60, height: 60)

                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
            }
            .glow(room.accentColor, radius: 12)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Helpers

    private func formattedCurrency(_ amount: Double) -> String {
        if amount >= 1000 {
            return String(format: "$%.0f", amount)
        }
        return amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "$%.0f", amount)
            : String(format: "$%.2f", amount)
    }
}

// MARK: - Scroll Offset Key

private struct MoneyScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Money Room Compose View

struct MoneyRoomComposeView: View {
    let room: MoneyRoom
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
                    // Room header
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(room.accentColor.opacity(0.2))
                                .frame(width: 38, height: 38)

                            Text(room.emoji)
                                .font(.system(size: 18))
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("MONEY TALKS")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(FanChatTheme.neonGreen)
                                .tracking(1)
                            Text(room.title)
                                .font(.system(size: 16, weight: .bold))
                                .foregroundColor(FanChatTheme.textPrimary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)

                    // Divider
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, room.accentColor.opacity(0.4), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)

                    // Text editor
                    ZStack(alignment: .topLeading) {
                        if content.isEmpty {
                            Text("Put your money where your mouth is...")
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

                    // Divider
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
            .navigationTitle("New Take")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
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
            .onAppear { isFocused = true }
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
        if content.count > maxCharacters { return FanChatTheme.neonRed }
        if content.count > maxCharacters - 20 { return FanChatTheme.neonOrange }
        return FanChatTheme.textTertiary
    }
}
