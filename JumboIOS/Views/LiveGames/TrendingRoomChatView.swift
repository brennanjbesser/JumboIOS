import SwiftUI
import Combine
import OSLog

private let logger = Logger(subsystem: "com.jumbo", category: "chat")

// MARK: - View Model

// NOTE: Trending rooms are isolated chat rooms — they are NOT tied to a real
// team. The post-scope id is the room's own UUID, never a real team id, so
// posts made in a trending room cannot leak into any real team chat. No seed
// posts are inserted; the empty room shows starter prompts. Real chat will
// flow through this view model once the chat backend is wired in.

@MainActor
class TrendingRoomChatViewModel: ObservableObject {
    let room: TrendingRoom
    // Resolved via the controlled-rollout accessor so this screen uses
    // RemoteChatService while the rest of the app stays on the mock.
    let service: any ChatServiceProtocol = AppServices.shared.chatServiceForChatScreens()

    @Published var posts: [Post] = []
    @Published var sortOption: FeedSortOption = .new {
        didSet {
            // Trending VM is realtime-driven (no fetch on init), so a
            // sort-pill change re-sorts the local cache instead of
            // re-fetching. Uses `sortedByFeed` so the formula stays in
            // lockstep with the `get_room_posts` RPC the other VMs use.
            posts = posts.sortedByFeed(sortOption)
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

    /// Chat-room identity for this trending room. Server posts get
    /// `room_id` from `chatRoom.roomId` and `room_type = "trending"`.
    let chatRoom: ChatRoom

    init(room: TrendingRoom) {
        self.room = room
        self.chatRoom = .trending(room.id)

        service.notificationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleNotification(notification)
            }
            .store(in: &cancellables)

        // Subscribe to realtime post inserts for THIS trending room's
        // chat scope. Server filter `room_id=eq.<uuid>` ensures isolation
        // from any team or game chat.
        let subscriptionService = service
        let scopeRoom = chatRoom
        let roomTitle = room.title
        logger.debug("🔥 TrendingRoomChatViewModel.init: room '\(roomTitle)' → subscribing room=\(scopeRoom.roomType):\(scopeRoom.roomId.uuidString)")
        Task { @MainActor in
            await subscriptionService.subscribeToPosts(room: scopeRoom)
        }
    }

    deinit {
        let subscriptionService = service
        let scopeRoom = chatRoom
        Task { @MainActor in
            await subscriptionService.unsubscribeFromPostScope(room: scopeRoom)
        }
    }

    // MARK: - Actions

    /// Returns `true` on accepted send, `false` on empty-content bail
    /// or network failure. Mirrors createReply's contract.
    @discardableResult
    func createPost(content: String) async -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            _ = try await service.createPost(content: trimmed, room: chatRoom, parentId: nil)
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
                // for the rationale. Without this, Hot/Top show the new
                // count but stale position until the user re-taps a pill.
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

    func refresh() async {
        newPostsCount = 0
        pendingPosts = []
    }

    // MARK: - Notifications

    /// Realtime delta handler. The Supabase RPC `get_room_posts` is the
    /// canonical source of feed order; after a delta we re-apply the
    /// matching client-side sort so the order stays consistent with what
    /// a fresh fetch would return.
    private func handleNotification(_ notification: ChatNotification) {
        switch notification {
        case .newPost(let post):
            guard post.parentId == nil else { return }
            guard post.belongs(to: chatRoom) else { return }
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
            break
        }
    }
}

// MARK: - Trending Room Chat View

struct TrendingRoomChatView: View {
    let room: TrendingRoom
    @StateObject private var viewModel: TrendingRoomChatViewModel
    @State private var showingComposer = false
    @State private var selectedPost: Post?
    @State private var showingReportSheet = false
    @State private var postToReport: Post?
    @State private var refreshRotation: Double = 0

    init(room: TrendingRoom) {
        self.room = room
        self._viewModel = StateObject(wrappedValue: TrendingRoomChatViewModel(room: room))
    }

    var body: some View {
        ZStack {
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            NoiseBackground()
                .opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Room header
                roomHeader

                // Sort picker
                sortPicker

                // Posts
                if viewModel.posts.isEmpty {
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
        .navigationTitle(room.title)
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
                    Task { await viewModel.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(room.accentColor)
                        .rotationEffect(.degrees(refreshRotation))
                }
            }
        }
        .navigationDestination(item: $selectedPost) { post in
            CasinoThreadView(parentPost: post)
        }
        .sheet(isPresented: $showingComposer) {
            TrendingRoomComposeView(room: room) { content in
                Task {
                    let succeeded = await viewModel.createPost(content: content)
                    if !succeeded {
                        print("⚠️ TrendingRoom post send failed — draft was lost (modal already dismissed)")
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
        .preferredColorScheme(.dark)
    }

    // MARK: - Room Header

    private var roomHeader: some View {
        RoomHeaderView(
            title: room.title,
            badge: RoomHeaderBadge(
                text: "TRENDING",
                systemImageName: "flame.fill",
                background: LinearGradient(
                    colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            ),
            icon: {
                RoomHeaderIcon(
                    fill: room.accentColor.opacity(0.2),
                    emoji: room.emoji
                )
            },
            secondaryContent: {
                // Live activity-dot + count today. Easy to extend
                // to "● 842 active · NBA" or similar by appending
                // segments with " · " separators inside this HStack.
                HStack(spacing: 6) {
                    Circle()
                        .fill(FanChatTheme.neonGreen)
                        .frame(width: 6, height: 6)
                    Text("\(room.activeUsers >= 1000 ? String(format: "%.1fk", Double(room.activeUsers) / 1000.0) : "\(room.activeUsers)") active")
                }
            }
        )
        .roomHeaderContainer(accentColor: room.accentColor)
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
                                      AnyShapeStyle(LinearGradient(colors: [room.accentColor, room.accentColor.opacity(0.7)], startPoint: .leading, endPoint: .trailing)) :
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
                    // Initial-load stagger (existing behavior).
                    .slideIn(delay: Double(index) * 0.05)
                    // Live-arrival transition. See
                    // GameRoomPlaceholderView for the rationale.
                    .transition(
                        .opacity.combined(with: .move(edge: .bottom))
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
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
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
    }

    // MARK: - Empty

    private var emptyView: some View {
        ScrollView {
            ChatStarterPrompts()
                .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Trending Room Compose View

struct TrendingRoomComposeView: View {
    let room: TrendingRoom
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
                            Text("POSTING TO")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(1)
                            Text(room.title)
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
                            Text("Join the conversation...")
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
