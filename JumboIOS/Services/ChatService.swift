import Foundation
import Combine

// MARK: - Chat Service Protocol
//
// All chat surfaces talk to chat through this protocol. View models obtain
// their conformer via `AppServices.shared.chatService` and never reference
// `MockChatService` directly — that's the swap point for the upcoming
// `RemoteChatService` (Supabase / our own backend). Methods here cover every
// member currently consumed by a view model; if a view needs something new,
// it goes on this protocol first, not on the mock.
@MainActor
protocol ChatServiceProtocol: AnyObject {
    // Identity & live store (read-only views into the underlying store so
    // view models can observe state without owning it).
    var currentUser: AnonymousUser { get }
    var posts: [Post] { get }

    // Synchronous reads (in-memory today; the remote conformer will back
    // these by a local cache hydrated from the backend).
    func getPost(by id: UUID) -> Post?
    func getUserVote(for postId: UUID) -> VoteType?

    // Async fetches.
    func fetchPosts(forTeamIds teamIds: Set<UUID>?, sortBy: FeedSortOption) async throws -> [Post]
    func fetchPostsForTeam(_ teamId: UUID, sortBy: FeedSortOption) async throws -> [Post]
    /// Room-scoped fetch. New chat surfaces (game / team / trending) use
    /// this; legacy callers may still use `fetchPostsForTeam`.
    func fetchPostsForRoom(_ room: ChatRoom, sortBy: FeedSortOption) async throws -> [Post]
    func fetchReplies(for postId: UUID) async throws -> [Post]
    func fetchReports() async throws -> [Report]

    // Mutations.
    func createPost(content: String, teamId: UUID, parentId: UUID?) async throws -> Post
    /// Room-scoped post creation. Sets `room_id` / `room_type` on the
    /// inserted row; `teamId` becomes optional metadata derived from the
    /// room (team rooms keep it; game/trending pass nil).
    func createPost(content: String, room: ChatRoom, parentId: UUID?) async throws -> Post

    /// Reply creation. Inherits room_id / room_type / team_id from the
    /// parent so we don't need to reconstruct a `ChatRoom` enum from a
    /// stored Post (which is impossible for game rooms — the enum carries
    /// homeTeamId/awayTeamId that aren't stored on the Post row).
    func createReply(content: String, parent: Post) async throws -> Post

    /// Best-effort author profile resolution + decoration. Returns the
    /// post with `authorUsername` / `authorAvatarEmoji` /
    /// `authorAvatarColorHex` populated from the `users` table when
    /// available, or unchanged on cache miss / lookup failure. Used by
    /// thread views to ensure the parent header renders the resolved
    /// identity even when the navigated-in Post snapshot was undecorated
    /// (deep link, refresh-after-restart, etc.).
    func resolveAuthor(for post: Post) async -> Post
    func vote(on postId: UUID, type: VoteType) async throws -> Post
    func removeVote(from postId: UUID) async throws -> Post
    func reportPost(_ postId: UUID, reason: ReportReason, additionalInfo: String?) async throws
    func blockUser(_ userId: UUID) async throws
    func unblockUser(_ userId: UUID) async throws
    func deletePost(_ postId: UUID) async throws
    func resolveReport(_ reportId: UUID, resolution: ReportResolution) async throws

    // Admin moderation.
    func hidePost(_ postId: UUID) async throws
    func approvePost(_ postId: UUID) async throws

    // Local-only helpers retained for legacy callers (orphaned views, dev
    // tooling). The remote conformer can stub these as no-ops.
    func injectPost(_ post: Post)
    func getLiveGames(for teamIds: Set<UUID>) -> [LiveGame]

    // Combine streams. Wire format must stay stable across mock and remote.
    var postsPublisher: AnyPublisher<[Post], Never> { get }
    var notificationPublisher: AnyPublisher<ChatNotification, Never> { get }

    // Realtime — backend conformers (e.g. RemoteChatService) override these
    // to subscribe to live post inserts; mock conformers can leave the
    // default no-ops in place. Subscriptions are scoped per `ChatRoom`,
    // and unsubscribing only affects the matching scope.
    func subscribeToPosts(room: ChatRoom) async
    func unsubscribeFromPostScope(room: ChatRoom) async
}

extension ChatServiceProtocol {
    /// Legacy convenience overload — top-level team-room posts. Routes
    /// through the room-based method.
    func createPost(content: String, teamId: UUID) async throws -> Post {
        try await createPost(content: content, teamId: teamId, parentId: nil)
    }

    /// Convenience for the room-based path — top-level posts skip parentId.
    func createPost(content: String, room: ChatRoom) async throws -> Post {
        try await createPost(content: content, room: room, parentId: nil)
    }

    /// Default no-op so the in-memory mock and any future conformer that
    /// doesn't ship realtime can ignore these without boilerplate.
    func subscribeToPosts(room: ChatRoom) async { }
    func unsubscribeFromPostScope(room: ChatRoom) async { }
}

// MARK: - Mock Chat Service
@MainActor
class MockChatService: ObservableObject, ChatServiceProtocol {
    static let shared = MockChatService()

    @Published private(set) var posts: [Post] = []
    @Published private(set) var currentUser: AnonymousUser
    @Published private(set) var votes: [UUID: VoteType] = [:]
    @Published private(set) var reports: [Report] = []

    private var rateLimitInfo = RateLimitInfo()

    private let postsSubject = PassthroughSubject<[Post], Never>()
    private let notificationSubject = PassthroughSubject<ChatNotification, Never>()

    var postsPublisher: AnyPublisher<[Post], Never> {
        postsSubject.eraseToAnyPublisher()
    }

    var notificationPublisher: AnyPublisher<ChatNotification, Never> {
        notificationSubject.eraseToAnyPublisher()
    }

    private init() {
        // Use the same userId as UserPreferences so posts are correctly attributed
        // to the current user and display their real profile (username, photo, emoji).
        self.currentUser = AnonymousUser(id: UserPreferences.shared.userId, isAdmin: true)
        setupMockData()
    }

    // MARK: - Mock Data Setup
    //
    // Intentionally inert. Mock data must NOT simulate real user activity —
    // no seeded posts, no fake authors, no timed "TOUCHDOWN!!!" injections.
    // All real chat will come from the backend in the next phase. The store
    // starts empty so any post visible in a chat is one that the current user
    // (or, eventually, the backend) actually created.
    private func setupMockData() {
        posts = []
        postsSubject.send(posts)
    }

    // MARK: - ChatServiceProtocol Implementation
    func fetchPosts(forTeamIds teamIds: Set<UUID>?, sortBy: FeedSortOption) async throws -> [Post] {
        try await Task.sleep(nanoseconds: 200_000_000)

        let preferences = UserPreferences.shared

        let filtered = posts.filter { post in
            if post.isHidden && !currentUser.isAdmin { return false }
            if preferences.isBlocked(post.authorId) { return false }
            if post.parentId != nil { return false } // Only top-level posts

            if let teamIds = teamIds, !teamIds.isEmpty {
                guard let postTeamId = post.teamId else { return false }
                return teamIds.contains(postTeamId)
            }

            return true
        }

        return sortPosts(filtered, by: sortBy)
    }

    func fetchPostsForTeam(_ teamId: UUID, sortBy: FeedSortOption) async throws -> [Post] {
        // Legacy path — treat as a team-room fetch.
        try await fetchPostsForRoom(.team(teamId), sortBy: sortBy)
    }

    func fetchPostsForRoom(_ room: ChatRoom, sortBy: FeedSortOption) async throws -> [Post] {
        try await Task.sleep(nanoseconds: 150_000_000)

        let preferences = UserPreferences.shared
        let scopeRoomId = room.roomId

        let filtered = posts.filter { post in
            if post.isHidden && !currentUser.isAdmin { return false }
            if preferences.isBlocked(post.authorId) { return false }
            if post.parentId != nil { return false }
            return post.roomId == scopeRoomId
        }

        return sortPosts(filtered, by: sortBy)
    }

    private func sortPosts(_ posts: [Post], by sortOption: FeedSortOption) -> [Post] {
        switch sortOption {
        case .hot:
            return posts.sorted { post1, post2 in
                let age1 = Date().timeIntervalSince(post1.createdAt) / 3600
                let age2 = Date().timeIntervalSince(post2.createdAt) / 3600
                let hot1 = Double(post1.score) / pow(age1 + 2, 1.5)
                let hot2 = Double(post2.score) / pow(age2 + 2, 1.5)
                return hot1 > hot2
            }
        case .new:
            return posts.sorted { $0.createdAt > $1.createdAt }
        case .top:
            return posts.sorted { $0.score > $1.score }
        }
    }

    func fetchReplies(for postId: UUID) async throws -> [Post] {
        try await Task.sleep(nanoseconds: 150_000_000)

        let preferences = UserPreferences.shared

        return posts
            .filter { $0.parentId == postId && !$0.isHidden }
            .filter { !preferences.isBlocked($0.authorId) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func createPost(content: String, teamId: UUID, parentId: UUID? = nil) async throws -> Post {
        // Legacy path — treat as a team-room post.
        try await createPost(content: content, room: .team(teamId), parentId: parentId)
    }

    func createPost(content: String, room: ChatRoom, parentId: UUID? = nil) async throws -> Post {
        let (allowed, reason) = rateLimitInfo.canPost()
        guard allowed else {
            throw ChatError.rateLimited(reason ?? "Please slow down")
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            throw ChatError.invalidContent("Post must be at least 2 characters")
        }
        guard trimmed.count <= 280 else {
            throw ChatError.invalidContent("Post must be 280 characters or less")
        }

        let lowercased = trimmed.lowercased()
        let spamPatterns = ["buy now", "click here", "free money", "dm me"]
        for pattern in spamPatterns {
            if lowercased.contains(pattern) {
                throw ChatError.invalidContent("Your post was flagged as spam")
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let newPost = Post(
            authorId: currentUser.id,
            content: trimmed,
            parentId: parentId,
            teamId: room.metadataTeamId,
            roomId: room.roomId,
            roomType: room.roomType
        )

        if let parentId = parentId,
           let parentIndex = posts.firstIndex(where: { $0.id == parentId }) {
            posts[parentIndex].replyCount += 1
        }

        posts.insert(newPost, at: 0)
        rateLimitInfo.recordPost()
        postsSubject.send(posts)
        notificationSubject.send(.newPost(newPost))

        return newPost
    }

    func createReply(content: String, parent: Post) async throws -> Post {
        // Mock conformer: route through the room-based createPost using
        // a synthetic ChatRoom that produces the parent's roomId. This
        // works for team rooms (we have parent.teamId); for other room
        // types the mock falls back on whatever .team derives from the
        // teamId field, which is fine for the mock's in-memory model.
        if let teamId = parent.teamId {
            return try await createPost(content: content, room: .team(teamId), parentId: parent.id)
        }
        // No teamId available — degrade to a plain team-id-less reply
        // by reusing the parent's room-id-deriving team. The mock
        // doesn't care about exact wire room types.
        return try await createPost(content: content, teamId: parent.roomId, parentId: parent.id)
    }

    func resolveAuthor(for post: Post) async -> Post {
        // Mock has no users table, so just return the post unchanged.
        // Identity in mock-mode is purely the deterministic anonymous
        // name + hash-derived avatar, which the View falls back to
        // automatically.
        return post
    }

    func vote(on postId: UUID, type: VoteType) async throws -> Post {
        guard let index = posts.firstIndex(where: { $0.id == postId }) else {
            throw ChatError.postNotFound
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        if let existingVote = votes[postId] {
            if existingVote == .upvote {
                posts[index].upvotes -= 1
            } else {
                posts[index].downvotes -= 1
            }
        }

        if type == .upvote {
            posts[index].upvotes += 1
        } else {
            posts[index].downvotes += 1
        }

        votes[postId] = type
        postsSubject.send(posts)
        notificationSubject.send(.postUpdated(posts[index]))

        return posts[index]
    }

    func removeVote(from postId: UUID) async throws -> Post {
        guard let index = posts.firstIndex(where: { $0.id == postId }) else {
            throw ChatError.postNotFound
        }

        try await Task.sleep(nanoseconds: 50_000_000)

        if let existingVote = votes[postId] {
            if existingVote == .upvote {
                posts[index].upvotes -= 1
            } else {
                posts[index].downvotes -= 1
            }
            votes.removeValue(forKey: postId)
        }

        postsSubject.send(posts)
        return posts[index]
    }

    func reportPost(_ postId: UUID, reason: ReportReason, additionalInfo: String?) async throws {
        guard posts.contains(where: { $0.id == postId }) else {
            throw ChatError.postNotFound
        }

        if reports.contains(where: { $0.postId == postId && $0.reporterId == currentUser.id }) {
            throw ChatError.alreadyReported
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let report = Report(
            reporterId: currentUser.id,
            postId: postId,
            reason: reason,
            additionalInfo: additionalInfo
        )

        reports.append(report)

        if let index = posts.firstIndex(where: { $0.id == postId }) {
            posts[index].reportCount += 1
            if posts[index].reportCount >= 5 {
                posts[index].isHidden = true
            }
        }

        postsSubject.send(posts)
    }

    func blockUser(_ userId: UUID) async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
        currentUser.blockedUserIds.insert(userId)
        UserPreferences.shared.blockUser(userId)
    }

    func unblockUser(_ userId: UUID) async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
        currentUser.blockedUserIds.remove(userId)
        UserPreferences.shared.unblockUser(userId)
    }

    // MARK: - Admin Functions
    func deletePost(_ postId: UUID) async throws {
        guard currentUser.isAdmin else {
            throw ChatError.unauthorized
        }

        guard let index = posts.firstIndex(where: { $0.id == postId }) else {
            throw ChatError.postNotFound
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        posts.remove(at: index)
        postsSubject.send(posts)
        notificationSubject.send(.postDeleted(postId))
    }

    func fetchReports() async throws -> [Report] {
        guard currentUser.isAdmin else {
            throw ChatError.unauthorized
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        return reports.sorted { $0.createdAt > $1.createdAt }
    }

    func resolveReport(_ reportId: UUID, resolution: ReportResolution) async throws {
        guard currentUser.isAdmin else {
            throw ChatError.unauthorized
        }

        guard let index = reports.firstIndex(where: { $0.id == reportId }) else {
            throw ChatError.reportNotFound
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        reports[index].isResolved = true
        reports[index].resolution = resolution

        if resolution == .postRemoved {
            let postId = reports[index].postId
            if let postIndex = posts.firstIndex(where: { $0.id == postId }) {
                posts[postIndex].isHidden = true
            }
        }

        postsSubject.send(posts)
    }

    func hidePost(_ postId: UUID) async throws {
        guard currentUser.isAdmin else {
            throw ChatError.unauthorized
        }

        guard let index = posts.firstIndex(where: { $0.id == postId }) else {
            throw ChatError.postNotFound
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        posts[index].isHidden = true
        postsSubject.send(posts)
    }

    func approvePost(_ postId: UUID) async throws {
        guard currentUser.isAdmin else {
            throw ChatError.unauthorized
        }

        guard let index = posts.firstIndex(where: { $0.id == postId }) else {
            throw ChatError.postNotFound
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        posts[index].isHidden = false
        posts[index].reportCount = 0
        postsSubject.send(posts)
    }

    // MARK: - Helper Methods
    func getUserVote(for postId: UUID) -> VoteType? {
        return votes[postId]
    }

    func getPost(by id: UUID) -> Post? {
        return posts.first { $0.id == id }
    }

    func injectPost(_ post: Post) {
        if !posts.contains(where: { $0.id == post.id }) {
            posts.append(post)
        }
    }

    /// Live games are owned by `LiveScoreService` now. This stub stays to
    /// satisfy the protocol shape used by legacy callers (e.g. orphaned
    /// `FeedView`); it intentionally returns no fake games.
    func getLiveGames(for teamIds: Set<UUID>) -> [LiveGame] {
        return []
    }
}

// MARK: - Live Game Model
struct LiveGame: Identifiable, Equatable {
    let id: UUID
    let homeTeam: SportsTeam
    let awayTeam: SportsTeam
    var homeScore: Int
    var awayScore: Int
    var status: LiveGameStatus
    var period: String
    var timeRemaining: String

    var displayTitle: String {
        "\(awayTeam.shortName) @ \(homeTeam.shortName)"
    }
}

enum LiveGameStatus: String, Codable {
    case scheduled = "Scheduled"
    case live = "Live"
    case halftime = "Halftime"
    case final_ = "Final"

    var isActive: Bool { self == .live || self == .halftime }
}

// MARK: - Errors
enum ChatError: LocalizedError {
    case postNotFound
    case rateLimited(String)
    case invalidContent(String)
    case unauthorized
    case alreadyReported
    case reportNotFound
    case networkError

    var errorDescription: String? {
        switch self {
        case .postNotFound:
            return "Post not found"
        case .rateLimited(let message):
            return message
        case .invalidContent(let message):
            return message
        case .unauthorized:
            return "You don't have permission to do that"
        case .alreadyReported:
            return "You've already reported this post"
        case .reportNotFound:
            return "Report not found"
        case .networkError:
            return "Network error. Please try again."
        }
    }
}
