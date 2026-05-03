import SwiftUI
import Combine

struct GameRoomView: View {
    @StateObject private var viewModel: GameRoomViewModel
    @State private var showingComposer = false
    @State private var selectedPost: Post?
    @State private var showingReportSheet = false
    @State private var postToReport: Post?
    @State private var refreshRotation: Double = 0

    /// Live-updating game read from the view model so the scoreboard reflects
    /// each LiveScoreService poll without rebuilding the view.
    private var game: LiveGame { viewModel.game }

    init(game: LiveGame) {
        self._viewModel = StateObject(wrappedValue: GameRoomViewModel(game: game))
    }

    var body: some View {
        ZStack {
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            NoiseBackground()
                .opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Scoreboard header
                scoreboardHeader

                // Sort picker
                sortPicker

                // Posts. Empty rooms show starter prompts (ChatStarterPrompts);
                // once the first real post arrives the feed renders normally.
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
        .navigationTitle(game.displayTitle)
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
                        .foregroundColor(FanChatTheme.neonOrange)
                        .rotationEffect(.degrees(refreshRotation))
                }
            }
        }
        .navigationDestination(item: $selectedPost) { post in
            CasinoThreadView(parentPost: post)
        }
        .sheet(isPresented: $showingComposer) {
            GameRoomComposeView(game: game) { content in
                // The compose modal already dismissed itself
                // synchronously — fire-and-forget the network call so
                // the user is back in the room instantly. Restoring
                // the typed text on failure would require either
                // re-presenting the modal or pre-filling the next open
                // (a UX change), so we just log here; the VM also
                // emits its own error log.
                Task {
                    let succeeded = await viewModel.createPost(content: content)
                    if !succeeded {
                        print("⚠️ GameRoom post send failed — draft was lost (modal already dismissed)")
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
        .onAppear {
            // User opened a live game chat: tighten polling cadence.
            LiveScoreService.shared.boostPolling()
        }
        .onDisappear {
            LiveScoreService.shared.restoreDefaultPolling()
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Scoreboard Header

    private var scoreboardHeader: some View {
        HStack(spacing: 0) {
            // Away team
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [game.awayTeam.primaryColor, game.awayTeam.secondaryColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)

                    Text(game.awayTeam.logoEmoji)
                        .font(.system(size: 20))
                }

                Text(game.awayTeam.shortName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(FanChatTheme.textSecondary)

                Text("\(game.awayScore)")
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .foregroundColor(FanChatTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)

            // Center status — matches live game card layout
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    LivePulseIndicator(animated: false)
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

            // Home team
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [game.homeTeam.primaryColor, game.homeTeam.secondaryColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)

                    Text(game.homeTeam.logoEmoji)
                        .font(.system(size: 20))
                }

                Text(game.homeTeam.shortName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(FanChatTheme.textSecondary)

                Text("\(game.homeScore)")
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .foregroundColor(FanChatTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(
            ZStack {
                FanChatTheme.backgroundSecondary

                LinearGradient(
                    colors: [
                        game.awayTeam.primaryColor.opacity(0.25),
                        game.awayTeam.primaryColor.opacity(0.08),
                        .clear,
                        game.homeTeam.primaryColor.opacity(0.08),
                        game.homeTeam.primaryColor.opacity(0.25)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        )
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
                                      AnyShapeStyle(LinearGradient(colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink], startPoint: .leading, endPoint: .trailing)) :
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
                    let team = teamForPost(post)
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
                    // Live-arrival transition. Fires only when the post
                    // is inserted inside `withAnimation { … }` — see
                    // GameRoomViewModel.handleNotification's .newPost
                    // branch. loadPosts assigns the array without
                    // wrapping, so cold-start cards skip this transition
                    // (only `.slideIn` plays). Vote / sort updates also
                    // skip this transition because their handler
                    // branches don't wrap their mutations either.
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
            await LiveScoreService.shared.refreshNow()
        }
    }

    // MARK: - New Post Button (FAB)

    private var newPostButton: some View {
        Button {
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
            showingComposer = true
        } label: {
            ZStack {
                Circle()
                    .fill(FanChatTheme.neonOrange.opacity(0.3))
                    .frame(width: 72, height: 72)
                    .blur(radius: 10)

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

    // MARK: - Loading & Empty

    private var loadingView: some View {
        VStack(spacing: 20) {
            CasinoSpinner()

            Text("Loading game room...")
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

    // MARK: - Helpers

    private func teamForPost(_ post: Post) -> SportsTeam? {
        if post.teamId == game.homeTeam.id {
            return game.homeTeam
        } else if post.teamId == game.awayTeam.id {
            return game.awayTeam
        }
        return game.homeTeam
    }
}

// MARK: - Game Room Compose View

struct GameRoomComposeView: View {
    let game: LiveGame
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
                    // Game header
                    HStack(spacing: 12) {
                        // Both team emojis
                        HStack(spacing: -8) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [game.awayTeam.primaryColor, game.awayTeam.secondaryColor],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 38, height: 38)

                                Text(game.awayTeam.logoEmoji)
                                    .font(.system(size: 18))
                            }
                            .zIndex(1)

                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [game.homeTeam.primaryColor, game.homeTeam.secondaryColor],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 38, height: 38)

                                Text(game.homeTeam.logoEmoji)
                                    .font(.system(size: 18))
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("POSTING TO")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(1)
                            Text(game.displayTitle)
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
                                colors: [.clear, FanChatTheme.neonOrange.opacity(0.4), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)

                    // Text editor
                    ZStack(alignment: .topLeading) {
                        if content.isEmpty {
                            Text("What's happening in this game?")
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
