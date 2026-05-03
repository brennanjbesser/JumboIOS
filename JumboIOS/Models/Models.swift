import Foundation

// MARK: - User Identity
struct AnonymousUser: Identifiable, Codable, Equatable {
    let id: UUID
    let deviceId: String
    let createdAt: Date
    var karma: Int
    var blockedUserIds: Set<UUID>
    var isAdmin: Bool

    init(id: UUID = UUID(), deviceId: String = UUID().uuidString, createdAt: Date = Date(), karma: Int = 0, blockedUserIds: Set<UUID> = [], isAdmin: Bool = false) {
        self.id = id
        self.deviceId = deviceId
        self.createdAt = createdAt
        self.karma = karma
        self.blockedUserIds = blockedUserIds
        self.isAdmin = isAdmin
    }
}

// MARK: - Post
//
// Posts are scoped to a chat ROOM, not a team. `roomId` (a deterministic
// UUID derived from the room kind + team ids — see `ChatRoom`) is what
// drives every fetch / filter / realtime subscription. `teamId` survives
// as nullable metadata only, useful for cross-feed surfacing or analytics.

struct Post: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let authorId: UUID
    let content: String
    let createdAt: Date
    var upvotes: Int
    var downvotes: Int
    var replyCount: Int
    let parentId: UUID? // nil for top-level posts
    let gameId: UUID?
    let teamId: UUID?
    /// Stable identity of the chat room this post belongs to.
    let roomId: UUID
    /// `"team"` / `"game"` / `"trending"`. Mirrors the `room_type` column.
    let roomType: String
    var isHidden: Bool // For moderation
    var reportCount: Int

    // MARK: - Author profile snapshot
    //
    // Resolved from the `users` table when the post is fetched / received.
    // `nil` means "couldn't resolve" — UI falls back to the deterministic
    // anonymous name + hash-derived avatar so display stays consistent
    // across devices even during the lookup race window.
    var authorUsername: String?
    var authorAvatarEmoji: String?
    var authorAvatarColorHex: String?

    /// YikYak-style net score. Single source of truth for vote display
    /// and ranking — UI should always render `post.score`, never raw
    /// `upvotes` / `downvotes`. The two underlying counters are derived
    /// from the `votes` table (active rows only) by `RemoteChatService`;
    /// `posts.upvotes` / `posts.downvotes` columns on the server are
    /// cache/analytics only and are not read by iOS for display.
    var score: Int { upvotes - downvotes }
    var isReply: Bool { parentId != nil }

    // Deterministic display name backed by the authorId's bytes (NOT
    // Swift's per-process-randomized UUID.hashValue). Same UUID →
    // same name on every device, every run. Used as a last-resort
    // fallback when the server's authorUsername is missing/empty.
    var anonymousName: String {
        Post.deterministicDisplayName(for: authorId)
    }

    /// Stable name from a user_id's first 4 bytes — produces the same
    /// "RedFan_42"-style label on every device because UUID byte access
    /// is deterministic (unlike `UUID.hashValue` which Swift salts per
    /// process for security).
    static func deterministicDisplayName(for userId: UUID) -> String {
        let colors = ["Red", "Blue", "Green", "Gold", "Silver", "Purple", "Orange", "Teal", "Crimson", "Navy"]
        let animals = ["Fan", "Hawk", "Tiger", "Bear", "Wolf", "Eagle", "Lion", "Shark", "Bull", "Panther"]
        let bytes = withUnsafeBytes(of: userId.uuid) { Array($0) }
        let colorIdx = Int(bytes[0]) % colors.count
        let animalIdx = Int(bytes[1]) % animals.count
        // Two-byte numeric suffix (0-999) gives 1k variations per
        // color/animal combo before collisions.
        let suffix = ((Int(bytes[2]) << 8) | Int(bytes[3])) % 1000
        return "\(colors[colorIdx])\(animals[animalIdx])_\(suffix)"
    }

    /// Stable emoji from a fixed palette, indexed by the user_id's
    /// 5th byte. Used to fill in missing avatar_emoji fields without
    /// per-device divergence.
    static func deterministicAvatarEmoji(for userId: UUID) -> String {
        let palette = ["🦁", "🐺", "🐻", "🦅", "🐯", "🦊",
                       "🦈", "🐲", "🦂", "🐍", "🦇", "🦉",
                       "🦬", "🦏", "🐘", "🦍", "🐊", "🦖",
                       "🔥", "⚡️", "💀", "👑", "🎯", "💎"]
        let bytes = withUnsafeBytes(of: userId.uuid) { Array($0) }
        let idx = Int(bytes[4]) % palette.count
        return palette[idx]
    }

    /// Stable avatar color hex from a fixed palette, indexed by the
    /// user_id's 6th byte. Used to fill in missing avatar_color
    /// fields without per-device divergence.
    static func deterministicAvatarColorHex(for userId: UUID) -> String {
        let palette = ["#FF6B6B", "#4ECDC4", "#45B7D1", "#FFA07A", "#98D8C8",
                       "#F7DC6F", "#BB8FCE", "#85C1E9", "#F8B739", "#52BE80",
                       "#E74C3C", "#16A085", "#2980B9", "#D35400", "#8E44AD",
                       "#27AE60"]
        let bytes = withUnsafeBytes(of: userId.uuid) { Array($0) }
        let idx = Int(bytes[5]) % palette.count
        return palette[idx]
    }

    init(
        id: UUID = UUID(),
        authorId: UUID,
        content: String,
        createdAt: Date = Date(),
        upvotes: Int = 0,
        downvotes: Int = 0,
        replyCount: Int = 0,
        parentId: UUID? = nil,
        gameId: UUID? = nil,
        teamId: UUID? = nil,
        // No defaults — `roomId` and `roomType` are load-bearing scope
        // identifiers. Defaulting them here would let real chat data slip
        // through with placeholder values and silently land in the wrong
        // room. Production paths derive both from a `ChatRoom`; preview /
        // sample data uses the `Post.preview(...)` factory below.
        roomId: UUID,
        roomType: String,
        isHidden: Bool = false,
        reportCount: Int = 0,
        authorUsername: String? = nil,
        authorAvatarEmoji: String? = nil,
        authorAvatarColorHex: String? = nil
    ) {
        self.id = id
        self.authorId = authorId
        self.content = content
        self.createdAt = createdAt
        self.upvotes = upvotes
        self.downvotes = downvotes
        self.replyCount = replyCount
        self.parentId = parentId
        self.gameId = gameId
        self.teamId = teamId
        self.roomId = roomId
        self.roomType = roomType
        self.isHidden = isHidden
        self.reportCount = reportCount
        self.authorUsername = authorUsername
        self.authorAvatarEmoji = authorAvatarEmoji
        self.authorAvatarColorHex = authorAvatarColorHex
    }

    /// True if this post lives in `room`. Use everywhere a chat surface
    /// asks "is this post mine to display?" — replaces raw `roomId == X`
    /// comparisons so the membership rule has one home.
    func belongs(to room: ChatRoom) -> Bool {
        roomId == room.roomId
    }
}

// MARK: - Post preview/sample factory
//
// Explicit, non-production constructor for SwiftUI previews and inline
// sample data. The main `Post.init` requires `roomId` + `roomType`
// because they drive real chat scoping; defaulting them in the main init
// risks silently producing miswired posts. This factory derives both
// from a `ChatRoom` (teamId-based when available, a fresh team-room
// otherwise) so previews don't need to know about chat rooms at all.

extension Post {
    static func preview(
        id: UUID = UUID(),
        authorId: UUID,
        content: String,
        createdAt: Date = Date(),
        upvotes: Int = 0,
        downvotes: Int = 0,
        replyCount: Int = 0,
        parentId: UUID? = nil,
        gameId: UUID? = nil,
        teamId: UUID? = nil,
        isHidden: Bool = false,
        reportCount: Int = 0
    ) -> Post {
        let room: ChatRoom = teamId.map { .team($0) } ?? .team(UUID())
        return Post(
            id: id,
            authorId: authorId,
            content: content,
            createdAt: createdAt,
            upvotes: upvotes,
            downvotes: downvotes,
            replyCount: replyCount,
            parentId: parentId,
            gameId: gameId,
            teamId: teamId,
            roomId: room.roomId,
            roomType: room.roomType,
            isHidden: isHidden,
            reportCount: reportCount
        )
    }
}

// MARK: - Vote
enum VoteType: String, Codable {
    case upvote
    case downvote
}

struct Vote: Identifiable, Codable, Equatable {
    let id: UUID
    let userId: UUID
    let postId: UUID
    let type: VoteType
    let createdAt: Date

    init(id: UUID = UUID(), userId: UUID, postId: UUID, type: VoteType, createdAt: Date = Date()) {
        self.id = id
        self.userId = userId
        self.postId = postId
        self.type = type
        self.createdAt = createdAt
    }
}

// MARK: - Report
enum ReportReason: String, Codable, CaseIterable {
    case spam = "Spam"
    case harassment = "Harassment"
    case hateSpeech = "Hate Speech"
    case misinformation = "Misinformation"
    case inappropriate = "Inappropriate Content"
    case other = "Other"
}

struct Report: Identifiable, Codable, Equatable {
    let id: UUID
    let reporterId: UUID
    let postId: UUID
    let reason: ReportReason
    let additionalInfo: String?
    let createdAt: Date
    var isResolved: Bool
    var resolution: ReportResolution?

    init(id: UUID = UUID(), reporterId: UUID, postId: UUID, reason: ReportReason, additionalInfo: String? = nil, createdAt: Date = Date(), isResolved: Bool = false, resolution: ReportResolution? = nil) {
        self.id = id
        self.reporterId = reporterId
        self.postId = postId
        self.reason = reason
        self.additionalInfo = additionalInfo
        self.createdAt = createdAt
        self.isResolved = isResolved
        self.resolution = resolution
    }
}

enum ReportResolution: String, Codable {
    case dismissed = "Dismissed"
    case postRemoved = "Post Removed"
    case userWarned = "User Warned"
    case userBanned = "User Banned"
}

// MARK: - Sports Data
struct Sport: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let icon: String // SF Symbol name

    static let allSports: [Sport] = [
        Sport(id: UUID(), name: "Football", icon: "football.fill"),
        Sport(id: UUID(), name: "Basketball", icon: "basketball.fill"),
        Sport(id: UUID(), name: "Baseball", icon: "baseball.fill"),
        Sport(id: UUID(), name: "Hockey", icon: "hockey.puck.fill"),
        Sport(id: UUID(), name: "Soccer", icon: "soccerball"),
        Sport(id: UUID(), name: "Tennis", icon: "tennis.racket"),
        Sport(id: UUID(), name: "Golf", icon: "figure.golf"),
        Sport(id: UUID(), name: "MMA", icon: "figure.martial.arts")
    ]
}

struct Team: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let shortName: String
    let sportId: UUID
    let primaryColor: String // Hex color
    let secondaryColor: String

    init(id: UUID = UUID(), name: String, shortName: String, sportId: UUID, primaryColor: String, secondaryColor: String) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.sportId = sportId
        self.primaryColor = primaryColor
        self.secondaryColor = secondaryColor
    }
}

enum GameStatus: String, Codable {
    case scheduled = "Scheduled"
    case live = "Live"
    case halftime = "Halftime"
    case final_ = "Final"

    var displayName: String { rawValue }
    var isActive: Bool { self == .live || self == .halftime }
}

struct Game: Identifiable, Codable, Equatable {
    let id: UUID
    let sportId: UUID
    let homeTeam: Team
    let awayTeam: Team
    var homeScore: Int
    var awayScore: Int
    let startTime: Date
    var status: GameStatus
    var currentPeriod: String?
    var timeRemaining: String?

    var displayTitle: String {
        "\(awayTeam.shortName) @ \(homeTeam.shortName)"
    }

    var scoreDisplay: String {
        "\(awayScore) - \(homeScore)"
    }

    init(id: UUID = UUID(), sportId: UUID, homeTeam: Team, awayTeam: Team, homeScore: Int = 0, awayScore: Int = 0, startTime: Date, status: GameStatus = .scheduled, currentPeriod: String? = nil, timeRemaining: String? = nil) {
        self.id = id
        self.sportId = sportId
        self.homeTeam = homeTeam
        self.awayTeam = awayTeam
        self.homeScore = homeScore
        self.awayScore = awayScore
        self.startTime = startTime
        self.status = status
        self.currentPeriod = currentPeriod
        self.timeRemaining = timeRemaining
    }
}

// MARK: - Rate Limiting
struct RateLimitInfo: Codable {
    var postCount: Int
    var windowStart: Date
    var lastPostTime: Date?

    static let maxPostsPerWindow = 10
    static let windowDuration: TimeInterval = 300 // 5 minutes
    static let minTimeBetweenPosts: TimeInterval = 5 // 5 seconds

    init(postCount: Int = 0, windowStart: Date = Date(), lastPostTime: Date? = nil) {
        self.postCount = postCount
        self.windowStart = windowStart
        self.lastPostTime = lastPostTime
    }

    mutating func resetIfNeeded() {
        if Date().timeIntervalSince(windowStart) > Self.windowDuration {
            postCount = 0
            windowStart = Date()
        }
    }

    func canPost() -> (allowed: Bool, reason: String?) {
        var mutableSelf = self
        mutableSelf.resetIfNeeded()

        if mutableSelf.postCount >= Self.maxPostsPerWindow {
            let waitTime = Int(Self.windowDuration - Date().timeIntervalSince(mutableSelf.windowStart))
            return (false, "Rate limit reached. Try again in \(waitTime) seconds.")
        }

        if let lastPost = lastPostTime,
           Date().timeIntervalSince(lastPost) < Self.minTimeBetweenPosts {
            return (false, "Please wait a few seconds between posts.")
        }

        return (true, nil)
    }

    mutating func recordPost() {
        resetIfNeeded()
        postCount += 1
        lastPostTime = Date()
    }
}

// MARK: - App State
enum FeedSortOption: String, CaseIterable {
    case hot = "Hot"
    case new = "New"
    case top = "Top"

    var icon: String {
        switch self {
        case .hot: return "flame.fill"
        case .new: return "clock.fill"
        case .top: return "arrow.up.circle.fill"
        }
    }

    /// Wire value for the `get_room_posts` RPC `sort_mode` parameter.
    /// Must match the literals the SQL function branches on.
    var rpcSortMode: String {
        switch self {
        case .hot: return "hot"
        case .new: return "new"
        case .top: return "top"
        }
    }
}

extension Array where Element == Post {
    /// Re-sort an array of posts to mirror what the `get_room_posts`
    /// RPC produced server-side. Used by view models to maintain feed
    /// order across realtime deltas — when a vote lands or a post
    /// arrives, the local ordering needs to be re-applied with the
    /// same formula the SQL function used so the position doesn't
    /// drift from what the server would return on a fresh fetch.
    ///
    /// IMPORTANT: keep this formula in lockstep with the SQL in
    /// `supabase_migration_get_room_posts_rpc.sql`. The SQL is the
    /// canonical source of feed order; this is the cache-coherence
    /// helper that prevents the order from going out of sync between
    /// fetches.
    func sortedByFeed(_ mode: FeedSortOption) -> [Post] {
        switch mode {
        case .new:
            return sorted { $0.createdAt > $1.createdAt }
        case .top:
            return sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.createdAt > rhs.createdAt
            }
        case .hot:
            let now = Date()
            return sorted { lhs, rhs in
                let lhsHot = Self.hotScore(for: lhs, at: now)
                let rhsHot = Self.hotScore(for: rhs, at: now)
                if lhsHot != rhsHot { return lhsHot > rhsHot }
                return lhs.createdAt > rhs.createdAt
            }
        }
    }

    /// Hot score: `score / pow(hoursOld + 2, 1.5)`. Same formula the
    /// RPC uses. `now` is passed in so a single sort call uses one
    /// consistent timestamp across all comparisons.
    private static func hotScore(for post: Post, at now: Date) -> Double {
        // `Swift.max` qualified explicitly because `max` inside an
        // Array extension would otherwise resolve to Array.max().
        let hoursOld = Swift.max(0, now.timeIntervalSince(post.createdAt)) / 3600.0
        return Double(post.score) / pow(hoursOld + 2.0, 1.5)
    }
}

// MARK: - Notification Types
enum ChatNotification: Equatable {
    case newPost(Post)
    case postUpdated(Post)
    case postDeleted(UUID)
    case scoreUpdate(Game)
}
