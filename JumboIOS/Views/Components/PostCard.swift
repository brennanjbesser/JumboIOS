import SwiftUI

struct PostCard: View {
    let post: Post
    let userVote: VoteType?
    let onUpvote: () -> Void
    let onDownvote: () -> Void
    let onReply: () -> Void
    let onReport: () -> Void
    let onBlock: () -> Void
    let onDelete: (() -> Void)?
    let isAdmin: Bool

    @State private var showingActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                // Anonymous avatar
                Circle()
                    .fill(avatarGradient)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text(post.anonymousName.prefix(1))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(post.anonymousName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)

                    Text(timeAgo(from: post.createdAt))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // More actions button
                Button {
                    showingActions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                }
            }

            // Content
            Text(post.content)
                .font(.system(size: 16))
                .foregroundColor(.primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            // Hidden indicator for admin
            if post.isHidden && isAdmin {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash.fill")
                    Text("Hidden from users")
                }
                .font(.system(size: 12))
                .foregroundColor(.orange)
            }

            // Actions bar
            HStack(spacing: 20) {
                // Voting
                HStack(spacing: 4) {
                    Button(action: onUpvote) {
                        Image(systemName: userVote == .upvote ? "arrow.up.circle.fill" : "arrow.up.circle")
                            .font(.system(size: 20))
                            .foregroundColor(userVote == .upvote ? .green : .secondary)
                    }

                    Text("\(post.score)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(scoreColor)
                        .frame(minWidth: 24)

                    Button(action: onDownvote) {
                        Image(systemName: userVote == .downvote ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 20))
                            .foregroundColor(userVote == .downvote ? .red : .secondary)
                    }
                }

                // Reply button
                Button(action: onReply) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .font(.system(size: 16))
                        if post.replyCount > 0 {
                            Text("\(post.replyCount)")
                                .font(.system(size: 13))
                        }
                    }
                    .foregroundColor(.secondary)
                }

                Spacer()

                // Report indicator
                if post.reportCount > 0 && isAdmin {
                    HStack(spacing: 2) {
                        Image(systemName: "flag.fill")
                        Text("\(post.reportCount)")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
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
    }

    private var avatarGradient: LinearGradient {
        let hash = post.authorId.hashValue
        let colors: [[Color]] = [
            [.blue, .purple],
            [.orange, .red],
            [.green, .teal],
            [.pink, .purple],
            [.yellow, .orange],
            [.cyan, .blue]
        ]
        let colorPair = colors[abs(hash) % colors.count]
        return LinearGradient(colors: colorPair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var scoreColor: Color {
        if post.score > 0 {
            return .green
        } else if post.score < 0 {
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

// MARK: - Compact Post Card for Replies
struct CompactPostCard: View {
    let post: Post
    let userVote: VoteType?
    let onUpvote: () -> Void
    let onDownvote: () -> Void
    let onReport: () -> Void
    let isAdmin: Bool

    @State private var showingActions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(resolvedAvatarFill)
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text(resolvedAvatarGlyph)
                            .font(.system(size: resolvedAvatarGlyphSize, weight: .bold))
                            .foregroundColor(.white)
                    )

                Text(resolvedDisplayName)
                    .font(.system(size: 13, weight: .medium))

                Text("·")
                    .foregroundColor(.secondary)

                Text(timeAgo(from: post.createdAt))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    showingActions = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }

            Text(post.content)
                .font(.system(size: 15))

            // Voting inline
            HStack(spacing: 12) {
                Button(action: onUpvote) {
                    Image(systemName: userVote == .upvote ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .font(.system(size: 16))
                        .foregroundColor(userVote == .upvote ? .green : .secondary)
                }

                Text("\(post.score)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(post.score > 0 ? .green : (post.score < 0 ? .red : .secondary))

                Button(action: onDownvote) {
                    Image(systemName: userVote == .downvote ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .font(.system(size: 16))
                        .foregroundColor(userVote == .downvote ? .red : .secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .confirmationDialog("Reply Actions", isPresented: $showingActions, titleVisibility: .hidden) {
            Button("Report", role: .destructive) {
                onReport()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Resolved author identity
    //
    // Server-decorated values when available; deterministic UUID-byte
    // fallbacks when missing. Never `UUID.hashValue` (per-process
    // randomized → different displays per device). No UserPreferences
    // override — the originating device reads the same server-resolved
    // identity as every other device, so cross-device displays
    // converge byte-for-byte on the same user_id.

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
        // Always emoji now (server-decorated or deterministic). Bumps
        // size accordingly via resolvedAvatarGlyphSize.
        return resolvedAvatarEmoji
    }

    private var resolvedAvatarGlyphSize: CGFloat { 14 }

    private var resolvedAvatarFill: AnyShapeStyle {
        if let hex = post.authorAvatarColorHex, !hex.isEmpty {
            return AnyShapeStyle(Color(hex: hex))
        }
        return AnyShapeStyle(Color(hex: Post.deterministicAvatarColorHex(for: post.authorId)))
    }

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        return "\(Int(interval / 86400))d"
    }
}

#Preview {
    VStack(spacing: 16) {
        PostCard(
            post: Post.preview(
                authorId: UUID(),
                content: "MAHOMES IS COOKING 🔥🔥🔥 This is the best game of the season!",
                upvotes: 42,
                downvotes: 3,
                replyCount: 12
            ),
            userVote: .upvote,
            onUpvote: {},
            onDownvote: {},
            onReply: {},
            onReport: {},
            onBlock: {},
            onDelete: {},
            isAdmin: true
        )

        CompactPostCard(
            post: Post.preview(
                authorId: UUID(),
                content: "Totally agree! He's on fire today",
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
    .background(Color(.systemGroupedBackground))
}
