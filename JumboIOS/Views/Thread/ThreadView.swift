import SwiftUI
import Combine

struct ThreadView: View {
    let parentPost: Post

    @StateObject private var viewModel: ThreadViewModel
    @State private var replyText = ""
    @State private var showingReportSheet = false
    @State private var postToReport: Post?
    @FocusState private var isReplyFocused: Bool

    init(parentPost: Post) {
        self.parentPost = parentPost
        self._viewModel = StateObject(wrappedValue: ThreadViewModel(parentPost: parentPost))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    // Parent post (larger)
                    parentPostView

                    // Replies header
                    if !viewModel.replies.isEmpty {
                        HStack {
                            Text("Replies")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)

                            Spacer()

                            Text("\(viewModel.replies.count)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(.tertiarySystemBackground)))
                        }
                        .padding(.horizontal, 16)
                    }

                    // Replies list
                    if viewModel.isLoading {
                        ProgressView()
                            .padding(.top, 20)
                    } else if viewModel.replies.isEmpty {
                        emptyRepliesView
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(viewModel.replies) { reply in
                                CompactPostCard(
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
                                // Live-arrival transition. Fires only when
                                // the reply is inserted inside a
                                // `withAnimation { … }` block — see
                                // ThreadViewModel.handleNotification.
                                // `loadReplies` sets the array without
                                // wrapping, so initial-load cards skip
                                // this transition entirely.
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
            QuickReplyBar(
                placeholder: "Add a reply...",
                text: $replyText,
                onSend: {
                    // Snapshot first, clear the input synchronously so
                    // typing feels instantaneous and chat-like. The
                    // keyboard stays open because we never touch
                    // `isReplyFocused`. If the send fails we restore
                    // the snapshot so the user can retry without
                    // retyping.
                    let pending = replyText
                    replyText = ""
                    Task {
                        let succeeded = await viewModel.createReply(content: pending)
                        if !succeeded {
                            replyText = pending
                            print("⚠️ ThreadView reply send failed — restored draft")
                        }
                    }
                },
                isSending: viewModel.isSending
            )
        }
        .background(Color(.systemGroupedBackground))
        .transientErrorBanner(viewModel.transientError)
        .navigationTitle("Thread")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingReportSheet) {
            if let post = postToReport {
                ReportSheet(post: post) { reason, additionalInfo in
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
    }

    private var parentPostView: some View {
        // Read everything from viewModel.parentPost so author + content
        // refresh when the VM resolves the profile or receives a
        // .postUpdated for the parent. The View's `let parentPost`
        // snapshot from init is stale by definition once any update
        // lands.
        let parent = viewModel.parentPost

        return VStack(alignment: .leading, spacing: 16) {
            // Author info
            HStack {
                Circle()
                    .fill(parentResolvedAvatarFill(parent))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Text(parentResolvedAvatarGlyph(parent))
                            .font(.system(size: parentResolvedAvatarGlyphSize(parent), weight: .bold))
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(parentResolvedDisplayName(parent))
                        .font(.system(size: 16, weight: .semibold))

                    Text(timeAgo(from: parent.createdAt))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            // Content
            Text(parent.content)
                .font(.system(size: 18))
                .lineSpacing(4)

            // Engagement stats
            HStack(spacing: 24) {
                // Votes
                HStack(spacing: 8) {
                    Button {
                        Task { await viewModel.voteOnParent(type: .upvote) }
                    } label: {
                        Image(systemName: viewModel.parentVote == .upvote ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .font(.system(size: 24))
                            .foregroundColor(viewModel.parentVote == .upvote ? .green : .secondary)
                    }

                    Text("\(viewModel.parentPost.score)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(scoreColor)

                    Button {
                        Task { await viewModel.voteOnParent(type: .downvote) }
                    } label: {
                        Image(systemName: viewModel.parentVote == .downvote ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 24))
                            .foregroundColor(viewModel.parentVote == .downvote ? .red : .secondary)
                    }
                }

                Divider()
                    .frame(height: 24)

                // Replies count
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 16))
                    Text("\(viewModel.parentPost.replyCount) replies")
                        .font(.system(size: 14))
                }
                .foregroundColor(.secondary)

                Spacer()
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var emptyRepliesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left")
                .font(.system(size: 32))
                .foregroundColor(.secondary)

            Text("No replies yet")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("Be the first to reply!")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
    }

    // MARK: - Parent author (server-driven, deterministic fallback)
    //
    // Identity comes from server-decorated fields. When a field is
    // missing or empty (historical row with blank username, etc.) we
    // fall back to a deterministic value derived from the user_id's
    // bytes — same UUID renders the same name/emoji/color on every
    // device because UUID byte access is identical across processes
    // (unlike `UUID.hashValue` which is per-process randomized).
    //
    // No `anonymousName` (now also deterministic), no UserPreferences
    // override, no random generation.

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
        // Always emoji-sized now since the deterministic fallback also
        // returns an emoji.
        return 22
    }

    private func parentResolvedAvatarFill(_ post: Post) -> AnyShapeStyle {
        if let hex = post.authorAvatarColorHex, !hex.isEmpty {
            return AnyShapeStyle(Color(hex: hex))
        }
        return AnyShapeStyle(Color(hex: Post.deterministicAvatarColorHex(for: post.authorId)))
    }

    private var scoreColor: Color {
        if viewModel.parentPost.score > 0 {
            return .green
        } else if viewModel.parentPost.score < 0 {
            return .red
        }
        return .secondary
    }

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d ago"
        }
    }
}

// MARK: - View Model
@MainActor
class ThreadViewModel: ObservableObject {
    @Published var parentPost: Post
    @Published var replies: [Post] = []
    @Published var isLoading = false
    @Published var isSending = false
    @Published var showError = false
    @Published var errorMessage: String?
    @Published var parentVote: VoteType?

    // Force RemoteChatService for thread screens so replies use the
    // real backend, matching the room VMs (GameRoom / TeamPage /
    // Trending) that all use chatServiceForChatScreens().
    let service: any ChatServiceProtocol = AppServices.shared.chatServiceForChatScreens()

    /// Posts whose vote/removeVote round-trip is currently in flight —
    /// see GameRoomViewModel for the rationale. Covers both replies
    /// (vote(on:type:)) and the parent (voteOnParent(type:)).
    private var inFlightVoteIds: Set<UUID> = []

    /// Anti-spam: rejects vote taps within 300ms of the previous.
    /// Shared across `vote` (replies) and `voteOnParent` so a rapid
    /// switch between reply-vote and parent-vote also throttles.
    private var lastVoteTime: Date = .distantPast

    /// Transient error toast — see GameRoomViewModel.transientError.
    /// Replaces the modal `.alert` for vote/reply paths so failures
    /// give fast non-blocking feedback. The legacy `showError(_:)`
    /// alert plumbing stays in place for any other path that needs
    /// it, but the chat-action catches now route here instead.
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

        // Live thread updates. We piggyback on whichever room channel is
        // already open (e.g., GameRoomViewModel pushed us into the nav
        // stack and is still subscribed to its room). Replies arrive
        // through the same room subscription as top-level posts because
        // they share room_id with their parent. Filter by
        // post.parentId == parentPost.id so we only see our thread.
        service.notificationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleNotification(notification)
            }
            .store(in: &cancellables)
    }

    /// Realtime delta handler for the thread.
    /// • newPost with parentId == parentPost.id → live reply, append in
    ///   chronological order.
    /// • postUpdated for parent → refresh parent (vote count, reply count).
    /// • postUpdated for a reply already in our list → refresh it.
    /// • postDeleted → drop from replies (or no-op if it's the parent;
    ///   nav back is the parent VM's job).
    private func handleNotification(_ notification: ChatNotification) {
        switch notification {
        case .newPost(let post):
            // Only replies to THIS thread's parent.
            guard post.parentId == parentPost.id else { return }
            // Dedupe — appending the same reply twice would render two
            // cards (e.g., originating-device echo + the realtime echo
            // both routing through ingestPost).
            guard !replies.contains(where: { $0.id == post.id }) else { return }

            // Insert at index 0 (newest-first). Wrapped in withAnimation
            // so the per-card `.transition(.opacity + .move(.bottom))`
            // fires for the new arrival — fade + slight upward slide
            // makes the reply feel like it's "arriving live". Initial
            // load (`loadReplies`) doesn't use withAnimation, so it
            // skips this transition entirely.
            withAnimation(AnimationConfig.snappy) {
                replies.insert(post, at: 0)
            }
            parentPost.replyCount = replies.count

        case .postUpdated(let post):
            if post.id == parentPost.id {
                parentPost = post
                // Override the server-side reply_count with what we
                // actually have loaded — local replies array is the
                // single source of truth for this thread's badge.
                parentPost.replyCount = replies.count
                // Keep the parent's UI vote-state pill in sync if it was
                // changed in another open view of the same post.
                parentVote = service.getUserVote(for: parentPost.id)
            } else if let index = replies.firstIndex(where: { $0.id == post.id }) {
                replies[index] = post
            }

        case .postDeleted(let postId):
            replies.removeAll { $0.id == postId }
            // Resync badge if a reply was removed.
            parentPost.replyCount = replies.count

        case .scoreUpdate:
            break
        }
    }

    func loadReplies() async {
        isLoading = true
        // Resolve the parent's author profile so the parent header
        // displays the same username/avatar/color as every other view
        // of this post. Idempotent — a no-op if the profile is already
        // cached. Done BEFORE fetchReplies so the header refresh isn't
        // gated on the replies query.
        parentPost = await service.resolveAuthor(for: parentPost)
        do {
            replies = try await service.fetchReplies(for: parentPost.id)
            // Trust the loaded replies as ground truth for the badge —
            // the parent row's stored reply_count can drift; what we
            // just fetched is what we'll actually display.
            parentPost.replyCount = replies.count
        } catch {
            showError(error)
        }
        isLoading = false
    }

    /// Returns `true` on accepted send, `false` on empty-content bail
    /// or network failure. Caller uses the return to decide whether to
    /// restore the input text it cleared optimistically.
    @discardableResult
    func createReply(content: String) async -> Bool {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        isSending = true
        defer { isSending = false }
        do {
            // `createReply` inherits room_id / room_type / team_id from
            // the parent — works uniformly for team / game / trending
            // rooms (unlike the legacy team-based createPost which
            // required parent.teamId).
            _ = try await service.createReply(content: content, parent: parentPost)
            // No manual append — `ingestPost` inside the service emitted
            // .newPost which our notification handler picks up and adds
            // to `replies` in chronological order. The same handler also
            // sees .postUpdated for the parent's reply_count bump and
            // refreshes the parent header.
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
        ThreadView(
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
