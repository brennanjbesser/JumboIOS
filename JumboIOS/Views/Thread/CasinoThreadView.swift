import SwiftUI
import Combine

struct CasinoThreadView: View {
    let parentPost: Post

    @StateObject private var viewModel: CasinoThreadViewModel
    @State private var replyText = ""
    @State private var showingReportSheet = false
    @State private var showingProfile = false
    @State private var profileAuthorId: UUID?
    @State private var postToReport: Post?
    @FocusState private var isReplyFocused: Bool

    init(parentPost: Post) {
        self.parentPost = parentPost
        self._viewModel = StateObject(wrappedValue: CasinoThreadViewModel(parentPost: parentPost))
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
                ScrollView {
                    VStack(spacing: 12) {
                        // Parent post (anchor — slightly heavier than replies)
                        parentPostView

                        // Replies header
                        if !viewModel.replies.isEmpty {
                            repliesHeader
                        }

                        // Replies list
                        if viewModel.isLoading {
                            loadingView
                        } else if viewModel.replies.isEmpty {
                            emptyRepliesView
                        } else {
                            LazyVStack(spacing: 6) {
                                ForEach(Array(viewModel.replies.enumerated()), id: \.element.id) { index, reply in
                                    CasinoReplyCard(
                                        post: reply,
                                        userVote: viewModel.getUserVote(for: reply.id),
                                        onUpvote: {
                                            Task { await viewModel.vote(on: reply, type: .upvote) }
                                        },
                                        onDownvote: {
                                            Task { await viewModel.vote(on: reply, type: .downvote) }
                                        },
                                        onReport: {
                                            postToReport = reply
                                            showingReportSheet = true
                                        },
                                        isAdmin: viewModel.service.currentUser.isAdmin
                                    )
                                    // Existing initial-load stagger.
                                    .slideIn(delay: Double(index) * 0.05)
                                    // Live-arrival transition. Fires only
                                    // when the reply is inserted inside a
                                    // `withAnimation { … }` block — see
                                    // CasinoThreadViewModel.handleNotification.
                                    // `loadReplies` sets the array without
                                    // wrapping, so initial-load cards
                                    // skip this transition entirely
                                    // (only `.slideIn` runs on first load).
                                    .transition(
                                        .opacity.combined(with: .move(edge: .bottom))
                                    )
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    .padding(.bottom, 100)
                }
                .scrollIndicators(.hidden)

                // Reply input bar
                CasinoReplyBar(
                    placeholder: "Add a reply...",
                    text: $replyText,
                    onSend: {
                        // Snapshot then clear immediately so typing
                        // feels chat-like; keyboard stays open because
                        // `isReplyFocused` is untouched. Restore the
                        // draft if send fails so the user can retry
                        // without retyping.
                        let pending = replyText
                        replyText = ""
                        Task {
                            let succeeded = await viewModel.createReply(content: pending)
                            if !succeeded {
                                replyText = pending
                                print("⚠️ CasinoThreadView reply send failed — restored draft")
                            }
                        }
                    },
                    isSending: viewModel.isSending
                )
            }
        }
        .transientErrorBanner(viewModel.transientError)
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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
            await viewModel.loadReplies()
        }
        .sheet(isPresented: $showingProfile) {
            if let authorId = profileAuthorId {
                UserProfileSheet(authorId: authorId)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Parent Post View
    //
    // Anchors the thread, so it stays slightly more prominent than
    // a reply card: bigger avatar (36 vs reply's 28), bolder
    // username (15 bold vs reply's 13 medium), larger content
    // (17 medium vs reply's 16 medium), wider corner radius
    // (14 vs reply's 10), and a one-tone-warmer background
    // (backgroundSecondary at full opacity vs reply's 0.4). All
    // dimensions are still well below the original heavy-card
    // values (48pt avatar, 18pt content, 26pt vote icons).
    private var parentPostView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Author info
            HStack {
                Button {
                    profileAuthorId = parentPost.authorId
                    showingProfile = true
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            // Strict server-driven identity — no local
                            // photo override. UserPreferences.avatarImageData
                            // isn't synced server-side, so reading it
                            // for a self-post would create a per-device
                            // display divergence, which is exactly what
                            // we're eliminating.
                            Circle()
                                .fill(parentResolvedAvatarFill(viewModel.parentPost))
                                .frame(width: 36, height: 36)

                            Text(parentResolvedAvatarGlyph(viewModel.parentPost))
                                .font(.system(size: parentResolvedAvatarGlyphSize(viewModel.parentPost), weight: .semibold))
                                .foregroundColor(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(parentResolvedDisplayName(viewModel.parentPost))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(FanChatTheme.textPrimary)

                            Text(timeAgo(from: viewModel.parentPost.createdAt))
                                .font(.system(size: 12))
                                .foregroundColor(FanChatTheme.textTertiary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()
            }

            // Content — read from viewModel.parentPost so any
            // .postUpdated for the parent (e.g., live edit, count
            // refresh) reflects without requiring a navigation reset.
            Text(viewModel.parentPost.content)
                .font(.system(size: 17, weight: .medium))
                .lineSpacing(4)
                .foregroundColor(FanChatTheme.textPrimary)

            // Engagement stats
            HStack(spacing: 16) {
                // Votes
                HStack(spacing: 8) {
                    Button {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        Task { await viewModel.voteOnParent(type: .upvote) }
                    } label: {
                        Image(systemName: viewModel.parentVote == .upvote ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(viewModel.parentVote == .upvote ? FanChatTheme.upvoteColor : FanChatTheme.textTertiary)
                            .glow(FanChatTheme.upvoteColor, radius: 4, isActive: viewModel.parentVote == .upvote)
                    }

                    FlipNumberView(
                        number: viewModel.parentPost.score,
                        color: scoreColor,
                        font: .system(size: 14, weight: .bold, design: .rounded)
                    )
                    .glow(scoreColor, radius: 2)

                    Button {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        Task { await viewModel.voteOnParent(type: .downvote) }
                    } label: {
                        Image(systemName: viewModel.parentVote == .downvote ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(viewModel.parentVote == .downvote ? FanChatTheme.downvoteColor : FanChatTheme.textTertiary)
                            .glow(FanChatTheme.downvoteColor, radius: 4, isActive: viewModel.parentVote == .downvote)
                    }
                }

                Spacer()

                // Replies count
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 13))
                        .foregroundColor(FanChatTheme.neonBlue)
                        .glow(FanChatTheme.neonBlue, radius: 2)

                    Text("\(viewModel.parentPost.replyCount)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FanChatTheme.textSecondary)

                    Text("replies")
                        .font(.system(size: 12))
                        .foregroundColor(FanChatTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var repliesHeader: some View {
        HStack {
            Text("REPLIES")
                .font(.system(size: 11, weight: .black))
                .foregroundColor(FanChatTheme.textTertiary)
                .tracking(2)

            Spacer()

            Text("\(viewModel.replies.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(FanChatTheme.neonBlue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(FanChatTheme.neonBlue.opacity(0.12))
                )
                .glow(FanChatTheme.neonBlue, radius: 2)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            CasinoSpinner()

            Text("Loading replies...")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(FanChatTheme.textTertiary)
        }
        .padding(.top, 40)
    }

    private var emptyRepliesView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(FanChatTheme.backgroundTertiary)
                    .frame(width: 70, height: 70)

                Image(systemName: "bubble.left")
                    .font(.system(size: 28))
                    .foregroundColor(FanChatTheme.neonBlue)
                    .glow(FanChatTheme.neonBlue, radius: 6)
            }

            Text("No replies yet")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(FanChatTheme.textPrimary)

            Text("Be the first to reply!")
                .font(.system(size: 14))
                .foregroundColor(FanChatTheme.textTertiary)
        }
        .padding(.top, 40)
    }

    private var avatarColors: [Color] {
        let hash = parentPost.authorId.hashValue
        let colors: [[Color]] = [
            [FanChatTheme.neonBlue, FanChatTheme.neonPurple],
            [FanChatTheme.neonOrange, FanChatTheme.neonPink],
            [FanChatTheme.neonGreen, FanChatTheme.neonBlue],
            [FanChatTheme.neonPink, FanChatTheme.neonPurple],
            [FanChatTheme.neonYellow, FanChatTheme.neonOrange],
            [FanChatTheme.neonBlue, FanChatTheme.neonGreen]
        ]
        return colors[abs(hash) % colors.count]
    }

    private var avatarGradient: LinearGradient {
        LinearGradient(colors: avatarColors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var avatarGlowColor: Color {
        avatarColors.first ?? FanChatTheme.neonPurple
    }

    // MARK: - Parent author (server-driven, deterministic fallback)
    //
    // See ThreadView for the rule. Server-decorated values when present;
    // deterministic UUID-byte-derived fallbacks when missing — the
    // same user_id always produces the same name/emoji/color on every
    // device.

    private func parentResolvedDisplayName(_ post: Post) -> String {
        if let username = post.authorUsername, !username.isEmpty {
            return username
        }
        return Post.deterministicDisplayName(for: post.authorId)
    }

    private func parentResolvedAvatarGlyph(_ post: Post) -> String {
        if let emoji = post.authorAvatarEmoji, !emoji.isEmpty {
            return emoji
        }
        return Post.deterministicAvatarEmoji(for: post.authorId)
    }

    private func parentResolvedAvatarGlyphSize(_ post: Post) -> CGFloat {
        return 18
    }

    private func parentResolvedAvatarFill(_ post: Post) -> AnyShapeStyle {
        if let hex = post.authorAvatarColorHex, !hex.isEmpty {
            return AnyShapeStyle(Color(hex: hex))
        }
        return AnyShapeStyle(Color(hex: Post.deterministicAvatarColorHex(for: post.authorId)))
    }

    private var scoreColor: Color {
        if viewModel.parentPost.score > 0 {
            return FanChatTheme.upvoteColor
        } else if viewModel.parentPost.score < 0 {
            return FanChatTheme.downvoteColor
        }
        return FanChatTheme.textSecondary
    }

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }
}

// MARK: - Casino Reply Card
struct CasinoReplyCard: View {
    let post: Post
    let userVote: VoteType?
    let onUpvote: () -> Void
    let onDownvote: () -> Void
    let onReport: () -> Void
    let isAdmin: Bool

    @State private var showVoteParticles = false
    @State private var isPressed = false
    @State private var showingProfile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Author info
            HStack(spacing: 8) {
                Button {
                    showingProfile = true
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            if post.authorId == UserPreferences.shared.userId,
                               let photoData = UserPreferences.shared.avatarImageData,
                               let uiImage = UIImage(data: photoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 28, height: 28)
                                    .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(resolvedAvatarFill)
                                    .frame(width: 28, height: 28)

                                Text(resolvedAvatarGlyph)
                                    .font(.system(size: resolvedAvatarGlyphSize, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                        }

                        Text(resolvedDisplayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(FanChatTheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showingProfile) {
                    UserProfileSheet(authorId: post.authorId)
                }

                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(FanChatTheme.textTertiary)

                Text(timeAgo(from: post.createdAt))
                    .font(.system(size: 11))
                    .foregroundColor(FanChatTheme.textTertiary)

                Spacer()

                // More options menu
                Menu {
                    Button(role: .destructive) {
                        onReport()
                    } label: {
                        Label("Report", systemImage: "flag")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(FanChatTheme.textTertiary)
                        .frame(width: 28, height: 28)
                }
            }

            // Content — primary element
            Text(post.content)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(FanChatTheme.textPrimary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            // Voting — inline, lighter weight
            HStack(spacing: 12) {
                Button {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    onUpvote()
                } label: {
                    Image(systemName: userVote == .upvote ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(userVote == .upvote ? FanChatTheme.upvoteColor : FanChatTheme.textTertiary)
                        .glow(FanChatTheme.upvoteColor, radius: 3, isActive: userVote == .upvote)
                }

                Text("\(post.score)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(scoreColor)

                Button {
                    let generator = UIImpactFeedbackGenerator(style: .light)
                    generator.impactOccurred()
                    onDownvote()
                } label: {
                    Image(systemName: userVote == .downvote ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(userVote == .downvote ? FanChatTheme.downvoteColor : FanChatTheme.textTertiary)
                        .glow(FanChatTheme.downvoteColor, radius: 3, isActive: userVote == .downvote)
                }

                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(FanChatTheme.backgroundSecondary.opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
        )
        .scaleEffect(isPressed ? 0.99 : 1)
        .animation(AnimationConfig.snappy, value: isPressed)
    }

    // MARK: - Resolved author identity
    //
    // Server-decorated values when available; deterministic UUID-byte
    // fallbacks when missing. Never `UUID.hashValue`, never
    // UserPreferences override — every device with the same user_id
    // renders the same name / emoji / color, even when the server
    // row's username field is empty (historical data).

    private var resolvedDisplayName: String {
        if let username = post.authorUsername, !username.isEmpty {
            return username
        }
        return Post.deterministicDisplayName(for: post.authorId)
    }

    private var resolvedAvatarEmoji: String {
        if let emoji = post.authorAvatarEmoji, !emoji.isEmpty {
            return emoji
        }
        return Post.deterministicAvatarEmoji(for: post.authorId)
    }

    private var resolvedAvatarGlyph: String {
        return resolvedAvatarEmoji
    }

    private var resolvedAvatarGlyphSize: CGFloat { 14 }

    private var resolvedAvatarFill: AnyShapeStyle {
        if let hex = post.authorAvatarColorHex, !hex.isEmpty {
            return AnyShapeStyle(Color(hex: hex))
        }
        return AnyShapeStyle(Color(hex: Post.deterministicAvatarColorHex(for: post.authorId)))
    }

    private var scoreColor: Color {
        if post.score > 0 {
            return FanChatTheme.upvoteColor
        } else if post.score < 0 {
            return FanChatTheme.downvoteColor
        }
        return FanChatTheme.textSecondary
    }

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

// MARK: - Casino Reply Bar
struct CasinoReplyBar: View {
    let placeholder: String
    @Binding var text: String
    let onSend: () -> Void
    let isSending: Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Text field
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(FanChatTheme.textPrimary)
                .lineLimit(4)
                .focused($isFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(FanChatTheme.backgroundTertiary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(
                            isFocused ? FanChatTheme.neonBlue.opacity(0.5) : Color.clear,
                            lineWidth: 1
                        )
                )
                .glow(FanChatTheme.neonBlue, radius: 4, isActive: isFocused)

            // Send button
            Button {
                onSend()
            } label: {
                ZStack {
                    if isSending {
                        ProgressView()
                            .tint(FanChatTheme.neonBlue)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(
                                canSend ?
                                LinearGradient(colors: [FanChatTheme.neonBlue, FanChatTheme.neonPurple], startPoint: .top, endPoint: .bottom) :
                                LinearGradient(colors: [FanChatTheme.textTertiary, FanChatTheme.textTertiary], startPoint: .top, endPoint: .bottom)
                            )
                            .glow(FanChatTheme.neonBlue, radius: 6, isActive: canSend)
                    }
                }
            }
            .disabled(!canSend || isSending)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            FanChatTheme.backgroundSecondary
                .overlay(
                    Rectangle()
                        .fill(FanChatTheme.backgroundTertiary)
                        .frame(height: 0.5),
                    alignment: .top
                )
        )
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - View Model
@MainActor
class CasinoThreadViewModel: ObservableObject {
    @Published var parentPost: Post
    @Published var replies: [Post] = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var showError = false
    @Published var errorMessage: String?
    @Published var parentVote: VoteType?

    // Force RemoteChatService for thread screens so replies use the
    // real backend, matching the room VMs.
    let service: any ChatServiceProtocol = AppServices.shared.chatServiceForChatScreens()

    /// Posts whose vote/removeVote round-trip is currently in flight —
    /// see GameRoomViewModel for the rationale. Covers both replies
    /// (vote(on:type:)) and the parent (voteOnParent(type:)).
    private var inFlightVoteIds: Set<UUID> = []

    /// Anti-spam: rejects vote taps within 300ms of the previous.
    /// Shared across `vote` and `voteOnParent`.
    private var lastVoteTime: Date = .distantPast

    /// Transient error toast — see GameRoomViewModel.transientError.
    /// Replaces the modal `.alert` for vote/reply paths so failures
    /// give fast non-blocking feedback. The legacy `showError(_:)`
    /// alert stays in place for any other path that needs it.
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

    private var cancellables = Set<AnyCancellable>()

    init(parentPost: Post) {
        self.parentPost = parentPost
        self.parentVote = service.getUserVote(for: parentPost.id)

        // Live thread updates — see ThreadViewModel.init for the
        // rationale. We piggyback on the room channel the parent VM
        // (GameRoom / TeamPage / Trending) already has open and filter
        // by parentId == parentPost.id.
        service.notificationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleNotification(notification)
            }
            .store(in: &cancellables)
    }

    private func handleNotification(_ notification: ChatNotification) {
        switch notification {
        case .newPost(let post):
            // Only replies to THIS thread's parent.
            guard post.parentId == parentPost.id else { return }
            // Dedupe (originating-device echo + realtime echo).
            guard !replies.contains(where: { $0.id == post.id }) else { return }

            // Insert at index 0 (newest-first). Wrapped in withAnimation
            // so the per-card `.transition(.opacity + .move(.bottom))`
            // fires for the new arrival. Initial load (`loadReplies`)
            // doesn't use withAnimation, so the transition is silent
            // there and only `.slideIn`'s staggered entrance plays.
            withAnimation(AnimationConfig.snappy) {
                replies.insert(post, at: 0)
            }
            parentPost.replyCount = replies.count

        case .postUpdated(let post):
            if post.id == parentPost.id {
                parentPost = post
                parentPost.replyCount = replies.count
                parentVote = service.getUserVote(for: parentPost.id)
            } else if let index = replies.firstIndex(where: { $0.id == post.id }) {
                replies[index] = post
            }

        case .postDeleted(let postId):
            replies.removeAll { $0.id == postId }
            parentPost.replyCount = replies.count

        case .scoreUpdate:
            break
        }
    }

    func loadReplies() async {
        isLoading = true
        // Resolve the parent's author profile so the parent header
        // displays the same identity as every other view of this post.
        // See ThreadViewModel.loadReplies for the rationale.
        parentPost = await service.resolveAuthor(for: parentPost)
        do {
            replies = try await service.fetchReplies(for: parentPost.id)
            parentPost.replyCount = replies.count
        } catch {
            showError(error)
        }
        isLoading = false
    }

    /// See ThreadViewModel.createReply for the contract.
    @discardableResult
    func createReply(content: String) async -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        isSending = true
        defer { isSending = false }
        do {
            // Inherit room scope from parent — works for team, game,
            // and trending rooms (unlike the legacy team-id-based
            // createPost path).
            _ = try await service.createReply(content: content, parent: parentPost)
            // No manual append — `ingestPost` in the service emits
            // .newPost and our handler picks it up. The same handler
            // sees .postUpdated for the parent's reply_count bump.
            return true
        } catch {
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

            if let index = replies.firstIndex(where: { $0.id == post.id }),
               let updatedPost = service.getPost(by: post.id) {
                replies[index] = updatedPost
            }
        } catch {
            showTransientError("Vote failed. Try again.")
        }
    }

    func voteOnParent(type: VoteType) async {
        if Date().timeIntervalSince(lastVoteTime) < 0.3 {
            return
        }
        lastVoteTime = Date()

        guard !inFlightVoteIds.contains(parentPost.id) else { return }
        inFlightVoteIds.insert(parentPost.id)
        defer { inFlightVoteIds.remove(parentPost.id) }

        do {
            if parentVote == type {
                _ = try await service.removeVote(from: parentPost.id)
                parentVote = nil
            } else {
                _ = try await service.vote(on: parentPost.id, type: type)
                parentVote = type
            }

            if let updated = service.getPost(by: parentPost.id) {
                parentPost = updated
            }
        } catch {
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
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

#Preview {
    NavigationStack {
        CasinoThreadView(
            parentPost: Post.preview(
                authorId: UUID(),
                content: "MAHOMES IS COOKING 🔥🔥🔥 This is hands down the best game of the season so far!",
                upvotes: 42,
                downvotes: 3,
                replyCount: 12
            )
        )
    }
}
