import SwiftUI

// MARK: - Casino Style Post Card
struct CasinoPostCard: View {
    let post: Post
    let team: SportsTeam?
    let userVote: VoteType?
    let onUpvote: () -> Void
    let onDownvote: () -> Void
    let onReply: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void
    let onDelete: (() -> Void)?
    let isAdmin: Bool

    @State private var showingActions = false
    @State private var showingProfile = false
    @State private var upvoteAnimating = false
    @State private var downvoteAnimating = false
    @State private var showUpvoteParticles = false
    @State private var showDownvoteParticles = false
    @State private var isPressed = false
    @State private var displayedScore: Int

    init(post: Post, team: SportsTeam?, userVote: VoteType?, onUpvote: @escaping () -> Void, onDownvote: @escaping () -> Void, onReply: @escaping () -> Void, onReport: @escaping () -> Void, onBlock: @escaping () -> Void, onDelete: (() -> Void)?, isAdmin: Bool) {
        self.post = post
        self.team = team
        self.userVote = userVote
        self.onUpvote = onUpvote
        self.onDownvote = onDownvote
        self.onReply = onReply
        self.onReport = onReport
        self.onBlock = onBlock
        self.onDelete = onDelete
        self.isAdmin = isAdmin
        self._displayedScore = State(initialValue: post.score)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // User info with emoji avatar
            HStack(spacing: 8) {
                // Tappable avatar + username → profile sheet
                Button {
                    showingProfile = true
                } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            if let photoData = avatarPhotoData,
                               let uiImage = UIImage(data: photoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 28, height: 28)
                                    .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(avatarGradientColor)
                                    .frame(width: 28, height: 28)

                                Text(avatarEmoji)
                                    .font(.system(size: 15))
                            }
                        }

                        Text(displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(FanChatTheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Text(post.createdAt.relativeTimeString)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(FanChatTheme.textTertiary)

                Button {
                    showingActions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(FanChatTheme.textTertiary)
                        .frame(width: 28, height: 28)
                }
            }
            .sheet(isPresented: $showingProfile) {
                UserProfileSheet(authorId: post.authorId)
            }

            // Content — most prominent element on the row
            Text(post.content)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(FanChatTheme.textPrimary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            // Hidden indicator for admin
            if post.isHidden && isAdmin {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash.fill")
                    Text("Hidden from users")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(FanChatTheme.neonOrange)
                .glow(FanChatTheme.neonOrange, radius: 4)
            }

            // Actions bar with voting — inline, lighter weight than before
            HStack(spacing: 0) {
                // Voting section
                HStack(spacing: 4) {
                    // Upvote button
                    ZStack {
                        // Particle burst
                        ConfettiBurstView(
                            colors: [FanChatTheme.neonGreen, FanChatTheme.neonYellow, .white],
                            isActive: $showUpvoteParticles
                        )

                        Button {
                            triggerUpvote()
                        } label: {
                            Image(systemName: userVote == .upvote ? "arrow.up.circle.fill" : "arrow.up.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(userVote == .upvote ? FanChatTheme.upvoteColor : FanChatTheme.textTertiary)
                                .scaleEffect(upvoteAnimating ? 1.2 : 1.0)
                                .glow(FanChatTheme.upvoteColor, radius: 3, isActive: userVote == .upvote)
                        }
                        .buttonStyle(.plain)
                    }

                    // Score with flip animation
                    ScoreDisplay(score: post.score, userVote: userVote)
                        .frame(minWidth: 24)

                    // Downvote button
                    ZStack {
                        // Particle burst
                        ParticleBurstView(
                            color: FanChatTheme.downvoteColor,
                            particleCount: 8,
                            isActive: $showDownvoteParticles
                        )

                        Button {
                            triggerDownvote()
                        } label: {
                            Image(systemName: userVote == .downvote ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(userVote == .downvote ? FanChatTheme.downvoteColor : FanChatTheme.textTertiary)
                                .scaleEffect(downvoteAnimating ? 1.2 : 1.0)
                                .glow(FanChatTheme.downvoteColor, radius: 3, isActive: userVote == .downvote)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // Reply button — plain inline, no capsule chip
                Button(action: onReply) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 14, weight: .regular))
                        if post.replyCount > 0 {
                            Text("\(post.replyCount)")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .foregroundColor(FanChatTheme.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if post.reportCount > 0 && isAdmin {
                    HStack(spacing: 4) {
                        Image(systemName: "flag.fill")
                        Text("\(post.reportCount)")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(FanChatTheme.neonRed)
                    .glow(FanChatTheme.neonRed, radius: 3)
                    .padding(.leading, 8)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FanChatTheme.backgroundSecondary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .scaleEffect(isPressed ? 0.99 : 1.0)
        .animation(AnimationConfig.snappy, value: isPressed)
        .confirmationDialog("Post Actions", isPresented: $showingActions, titleVisibility: .hidden) {
            Button("Report Post", role: .destructive) {
                onReport()
            }

            Button("Block User", role: .destructive) {
                onBlock()
            }

            if isAdmin, let onDelete = onDelete {
                Button("Delete Post (Admin)", role: .destructive) {
                    onDelete()
                }
            }

            Button("Cancel", role: .cancel) { }
        }
        .onChange(of: post.score) { _, newValue in
            displayedScore = newValue
        }
    }

    // MARK: - Actions
    private func triggerUpvote() {
        withAnimation(AnimationConfig.voteBounce) {
            upvoteAnimating = true
        }
        showUpvoteParticles = true

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(AnimationConfig.voteBounce) {
                upvoteAnimating = false
            }
        }

        onUpvote()
    }

    private func triggerDownvote() {
        withAnimation(AnimationConfig.voteBounce) {
            downvoteAnimating = true
        }
        showDownvoteParticles = true

        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(AnimationConfig.voteBounce) {
                downvoteAnimating = false
            }
        }

        onDownvote()
    }

    // MARK: - Computed Properties

    private var isCurrentUser: Bool {
        post.authorId == UserPreferences.shared.userId
    }

    private var displayName: String {
        if isCurrentUser {
            return UserPreferences.shared.displayName
        }
        if let resolved = post.authorUsername, !resolved.isEmpty {
            return resolved
        }
        return post.anonymousName
    }

    private var avatarEmoji: String {
        if isCurrentUser {
            return UserPreferences.shared.avatarEmoji
        }
        if let resolved = post.authorAvatarEmoji, !resolved.isEmpty {
            return resolved
        }
        let hash = abs(post.authorId.hashValue)
        return AvatarEmojis.all[hash % AvatarEmojis.all.count]
    }

    private var avatarPhotoData: Data? {
        // Avatar photos are local-device-only (avatarImageData lives in
        // UserDefaults and isn't synced to the server). For other users
        // we always fall back to the gradient + emoji.
        if isCurrentUser {
            return UserPreferences.shared.avatarImageData
        }
        return nil
    }

    private var avatarGradientColor: Color {
        if isCurrentUser {
            return UserPreferences.shared.avatarColor
        }
        if let hex = post.authorAvatarColorHex, !hex.isEmpty {
            return Color(hex: hex)
        }
        return FanChatTheme.backgroundTertiary
    }
}

// MARK: - Score Display with Animation
struct ScoreDisplay: View {
    let score: Int
    let userVote: VoteType?

    @State private var isAnimating = false
    @State private var displayedScore: Int

    init(score: Int, userVote: VoteType?) {
        self.score = score
        self.userVote = userVote
        self._displayedScore = State(initialValue: score)
    }

    var body: some View {
        Text("\(displayedScore)")
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(scoreColor)
            .scaleEffect(isAnimating ? 1.2 : 1.0)
            .glow(scoreColor, radius: score != 0 ? 2 : 0)
            .onChange(of: score) { oldValue, newValue in
                if oldValue != newValue {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                        isAnimating = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        displayedScore = newValue
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                            isAnimating = false
                        }
                    }
                }
            }
    }

    private var scoreColor: Color {
        if userVote == .upvote || score > 0 {
            return FanChatTheme.upvoteColor
        } else if userVote == .downvote || score < 0 {
            return FanChatTheme.downvoteColor
        }
        return FanChatTheme.textSecondary
    }
}

// MARK: - Neon Team Badge
struct NeonTeamBadge: View {
    let team: SportsTeam

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [team.primaryColor, team.secondaryColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 30, height: 30)
                    .glow(team.primaryColor, radius: 4)

                Text(team.logoEmoji)
                    .font(.system(size: 15))
            }

            Text(team.name)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(FanChatTheme.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(team.primaryColor.opacity(0.2))
        )
        .overlay(
            Capsule()
                .stroke(team.primaryColor.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Compact Casino Post Card (for replies)
struct CompactCasinoPostCard: View {
    let post: Post
    let userVote: VoteType?
    let onUpvote: () -> Void
    let onDownvote: () -> Void
    let onReport: () -> Void
    let isAdmin: Bool

    @State private var showingActions = false
    @State private var showingProfile = false
    @State private var upvoteAnimating = false
    @State private var downvoteAnimating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // Tappable avatar + username → profile sheet
                Button {
                    showingProfile = true
                } label: {
                    HStack(spacing: 0) {
                        ZStack {
                            if let photoData = compactAvatarPhotoData,
                               let uiImage = UIImage(data: photoData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 28, height: 28)
                                    .clipShape(Circle())
                            } else {
                                Circle()
                                    .fill(compactIsCurrentUser ? UserPreferences.shared.avatarColor : FanChatTheme.backgroundSecondary)
                                    .frame(width: 28, height: 28)

                                Text(avatarEmoji)
                                    .font(.system(size: 15))
                            }
                        }

                        Text(compactDisplayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(FanChatTheme.textPrimary)
                            .padding(.leading, 6)
                    }
                }
                .buttonStyle(.plain)

                Text("·")
                    .foregroundColor(FanChatTheme.textTertiary)
                    .padding(.leading, 4)

                Text(post.createdAt.compactTimeString)
                    .font(.system(size: 12))
                    .foregroundColor(FanChatTheme.textTertiary)

                Spacer()

                Button {
                    showingActions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundColor(FanChatTheme.textTertiary)
                }
            }
            .sheet(isPresented: $showingProfile) {
                UserProfileSheet(authorId: post.authorId)
            }

            Text(post.content)
                .font(.system(size: 15))
                .foregroundColor(FanChatTheme.textPrimary)

            // Voting inline
            HStack(spacing: 8) {
                Button {
                    // Light impact to match CasinoReplyCard's compact-
                    // surface convention (smaller card → lighter haptic).
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(AnimationConfig.voteBounce) { upvoteAnimating = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation { upvoteAnimating = false }
                    }
                    onUpvote()
                } label: {
                    Image(systemName: userVote == .upvote ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.system(size: 20))
                        .foregroundColor(userVote == .upvote ? FanChatTheme.upvoteColor : FanChatTheme.textTertiary)
                        .scaleEffect(upvoteAnimating ? 1.3 : 1.0)
                        .glow(FanChatTheme.upvoteColor, radius: 4, isActive: userVote == .upvote)
                }
                .buttonStyle(.plain)

                Text("\(post.score)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(scoreColor)

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(AnimationConfig.voteBounce) { downvoteAnimating = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation { downvoteAnimating = false }
                    }
                    onDownvote()
                } label: {
                    Image(systemName: userVote == .downvote ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 20))
                        .foregroundColor(userVote == .downvote ? FanChatTheme.downvoteColor : FanChatTheme.textTertiary)
                        .scaleEffect(downvoteAnimating ? 1.3 : 1.0)
                        .glow(FanChatTheme.downvoteColor, radius: 4, isActive: userVote == .downvote)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FanChatTheme.backgroundTertiary)
        )
        .confirmationDialog("Reply Actions", isPresented: $showingActions, titleVisibility: .hidden) {
            Button("Report", role: .destructive) {
                onReport()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var compactIsCurrentUser: Bool {
        post.authorId == UserPreferences.shared.userId
    }

    private var compactDisplayName: String {
        if compactIsCurrentUser {
            return UserPreferences.shared.displayName
        }
        if let resolved = post.authorUsername, !resolved.isEmpty {
            return resolved
        }
        return post.anonymousName
    }

    private var avatarEmoji: String {
        if compactIsCurrentUser {
            return UserPreferences.shared.avatarEmoji
        }
        if let resolved = post.authorAvatarEmoji, !resolved.isEmpty {
            return resolved
        }
        let hash = abs(post.authorId.hashValue)
        return AvatarEmojis.all[hash % AvatarEmojis.all.count]
    }

    private var compactAvatarPhotoData: Data? {
        compactIsCurrentUser ? UserPreferences.shared.avatarImageData : nil
    }

    private var scoreColor: Color {
        if post.score > 0 { return FanChatTheme.upvoteColor }
        else if post.score < 0 { return FanChatTheme.downvoteColor }
        return FanChatTheme.textSecondary
    }
}

#Preview {
    ZStack {
        FanChatTheme.backgroundPrimary.ignoresSafeArea()

        VStack(spacing: 16) {
            CasinoPostCard(
                post: Post.preview(
                    authorId: UUID(),
                    content: "MAHOMES IS COOKING 🔥🔥🔥 This is the best game of the season!",
                    upvotes: 42,
                    downvotes: 3,
                    replyCount: 12,
                    teamId: TeamDatabase.nflTeams.first?.id
                ),
                team: TeamDatabase.nflTeams.first,
                userVote: .upvote,
                onUpvote: {},
                onDownvote: {},
                onReply: {},
                onReport: {},
                onBlock: {},
                onDelete: {},
                isAdmin: false
            )

            CompactCasinoPostCard(
                post: Post.preview(
                    authorId: UUID(),
                    content: "Totally agree! He's unstoppable today",
                    upvotes: 8,
                    downvotes: 1,
                    parentId: UUID()
                ),
                userVote: nil,
                onUpvote: {},
                onDownvote: {},
                onReport: {},
                isAdmin: false
            )
        }
        .padding()
    }
}
