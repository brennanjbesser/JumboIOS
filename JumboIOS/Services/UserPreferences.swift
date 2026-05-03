import Foundation
import SwiftUI
import Combine

// MARK: - Available Avatar Emojis
struct AvatarEmojis {
    static let all: [String] = [
        "🦁", "🐺", "🐻", "🦅", "🐯", "🦊",
        "🦈", "🐲", "🦂", "🐍", "🦇", "🦉",
        "🦬", "🦏", "🐘", "🦍", "🐊", "🦖",
        "🔥", "⚡️", "💀", "👑", "🎯", "💎"
    ]

    static var random: String {
        all.randomElement() ?? "🦁"
    }
}

// MARK: - User Preferences Manager
@MainActor
class UserPreferences: ObservableObject {
    static let shared = UserPreferences()

    // MARK: - Published Properties
    @Published var hasCompletedOnboarding: Bool {
        didSet { save() }
    }

    @Published var followedTeamIds: Set<UUID> {
        didSet { save() }
    }

    @Published var userId: UUID

    @Published var blockedUserIds: Set<UUID> {
        didSet { save() }
    }

    // MARK: - User Profile Customization
    //
    // Server-synced fields (username/emoji/colorHex) fire
    // `profileChangedPublisher` on every set so RemoteChatService
    // can push the latest values to public.users — without this,
    // edits would only persist locally and other devices would
    // continue showing the stale identity from the last upsert.
    // `avatarImageData` is local-only (no server column for it),
    // so it does NOT publish.

    @Published var username: String {
        didSet {
            save()
            profileChangedSubject.send()
        }
    }

    @Published var avatarEmoji: String {
        didSet {
            save()
            profileChangedSubject.send()
        }
    }

    @Published var avatarImageData: Data? {
        didSet { save() }
    }

    var hasCustomPhoto: Bool {
        avatarImageData != nil
    }

    @Published var avatarColorHex: String {
        didSet {
            save()
            profileChangedSubject.send()
        }
    }

    /// Fires whenever a server-synced profile field
    /// (username / avatarEmoji / avatarColorHex) is mutated.
    /// Subscribers debounce and push to public.users.
    private let profileChangedSubject = PassthroughSubject<Void, Never>()
    var profileChangedPublisher: AnyPublisher<Void, Never> {
        profileChangedSubject.eraseToAnyPublisher()
    }

    var avatarColor: Color {
        Color(hex: avatarColorHex)
    }

    // MARK: - Extended Profile
    @Published var bio: String {
        didSet { save() }
    }

    @Published var socialTwitter: String {
        didSet { save() }
    }

    @Published var socialInstagram: String {
        didSet { save() }
    }

    @Published var socialTikTok: String {
        didSet { save() }
    }

    var hasBio: Bool {
        !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSocialLinks: Bool {
        !socialTwitter.isEmpty || !socialInstagram.isEmpty || !socialTikTok.isEmpty
    }

    // MARK: - Apple Sign In Info
    @Published var appleUserId: String? {
        didSet { save() }
    }

    @Published var appleEmail: String? {
        didSet { save() }
    }

    // MARK: - Computed Properties
    var followedTeams: [SportsTeam] {
        followedTeamIds.compactMap { id in
            TeamDatabase.allTeams.first { $0.id == id }
        }.sorted { $0.fullName < $1.fullName }
    }

    var followedTeamsByLeague: [League: [SportsTeam]] {
        Dictionary(grouping: followedTeams, by: { $0.league })
    }

    var canProceedFromOnboarding: Bool {
        followedTeamIds.count >= Self.minTeamsRequired && isValidUsername(username)
    }

    var displayName: String {
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? generateAnonymousName() : trimmed
    }

    var isAuthenticated: Bool {
        appleUserId != nil
    }

    // MARK: - Constants
    static let minTeamsRequired = 3
    static let maxTeamsAllowed = 50
    static let maxUsernameLength = 20
    static let minUsernameLength = 2
    static let maxBioLength = 120
    static let maxSocialHandleLength = 30

    // MARK: - UserDefaults Keys
    private enum Keys {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let followedTeamIds = "followedTeamIds"
        static let userId = "userId"
        static let blockedUserIds = "blockedUserIds"
        static let username = "username"
        static let avatarEmoji = "avatarEmoji"
        static let avatarImageData = "avatarImageData"
        static let avatarColorHex = "avatarColorHex"
        static let bio = "userBio"
        static let socialTwitter = "socialTwitter"
        static let socialInstagram = "socialInstagram"
        static let socialTikTok = "socialTikTok"
        static let appleUserId = "appleUserId"
        static let appleEmail = "appleEmail"
    }

    // MARK: - Initialization
    private init() {
        // Load from UserDefaults
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Keys.hasCompletedOnboarding)

        // Load followed teams
        if let data = UserDefaults.standard.data(forKey: Keys.followedTeamIds),
           let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) {
            self.followedTeamIds = ids
        } else {
            self.followedTeamIds = []
        }

        // Load or create user ID
        if let idString = UserDefaults.standard.string(forKey: Keys.userId),
           let id = UUID(uuidString: idString) {
            self.userId = id
        } else {
            let newId = UUID()
            self.userId = newId
            UserDefaults.standard.set(newId.uuidString, forKey: Keys.userId)
        }

        // Load blocked users
        if let data = UserDefaults.standard.data(forKey: Keys.blockedUserIds),
           let ids = try? JSONDecoder().decode(Set<UUID>.self, from: data) {
            self.blockedUserIds = ids
        } else {
            self.blockedUserIds = []
        }

        // Load username
        self.username = UserDefaults.standard.string(forKey: Keys.username) ?? ""

        // Load avatar emoji
        self.avatarEmoji = UserDefaults.standard.string(forKey: Keys.avatarEmoji) ?? AvatarEmojis.random

        // Load avatar image
        self.avatarImageData = UserDefaults.standard.data(forKey: Keys.avatarImageData)

        // Load avatar color
        self.avatarColorHex = UserDefaults.standard.string(forKey: Keys.avatarColorHex) ?? "#00D9FF"

        // Load extended profile
        self.bio = UserDefaults.standard.string(forKey: Keys.bio) ?? ""
        self.socialTwitter = UserDefaults.standard.string(forKey: Keys.socialTwitter) ?? ""
        self.socialInstagram = UserDefaults.standard.string(forKey: Keys.socialInstagram) ?? ""
        self.socialTikTok = UserDefaults.standard.string(forKey: Keys.socialTikTok) ?? ""

        // Load Apple Sign In info
        self.appleUserId = UserDefaults.standard.string(forKey: Keys.appleUserId)
        self.appleEmail = UserDefaults.standard.string(forKey: Keys.appleEmail)
    }

    // MARK: - Anonymous Name Generator (fallback)
    private func generateAnonymousName() -> String {
        let colors = ["Red", "Blue", "Green", "Gold", "Silver", "Purple", "Orange", "Teal", "Crimson", "Navy"]
        let animals = ["Fan", "Hawk", "Tiger", "Bear", "Wolf", "Eagle", "Lion", "Shark", "Bull", "Panther"]
        let hash = userId.hashValue
        let colorIndex = abs(hash) % colors.count
        let animalIndex = abs(hash / colors.count) % animals.count
        return "\(colors[colorIndex]) \(animals[animalIndex])"
    }

    // MARK: - Username Validation
    func isValidUsername(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= Self.minUsernameLength && trimmed.count <= Self.maxUsernameLength
    }

    // MARK: - Team Management
    func followTeam(_ team: SportsTeam) {
        guard followedTeamIds.count < Self.maxTeamsAllowed else {
            print("⚠️ followTeam BLOCKED: at max \(followedTeamIds.count) teams")
            return
        }
        print("✅ followTeam: \(team.fullName) id=\(team.id)")
        followedTeamIds.insert(team.id)
        print("   followedTeamIds now has \(followedTeamIds.count) items")
    }

    func unfollowTeam(_ team: SportsTeam) {
        print("❌ unfollowTeam: \(team.fullName) id=\(team.id)")
        followedTeamIds.remove(team.id)
        print("   followedTeamIds now has \(followedTeamIds.count) items")
    }

    func toggleTeam(_ team: SportsTeam) {
        print("🔄 toggleTeam called: \(team.fullName), currently following: \(isFollowing(team))")
        if isFollowing(team) {
            unfollowTeam(team)
        } else {
            followTeam(team)
        }
    }

    func isFollowing(_ team: SportsTeam) -> Bool {
        followedTeamIds.contains(team.id)
    }

    #if DEBUG
    // MARK: - Debug
    //
    // DEBUG-ONLY: clear the device's local user identity (userId + profile
    // fields) and reinitialize to fresh defaults. Lets the same physical
    // device simulate a different user — useful for testing chat across
    // simulator + iPhone with one Apple ID. Followed teams, onboarding
    // state, and block list are intentionally preserved (those are content
    // preferences, not identity).
    //
    // Does NOT touch Supabase. Old userId's posts/votes/users-row stay on
    // the server under the old id; the new identity creates fresh rows on
    // first post via the existing `ensureCurrentUserExists` path.
    //
    // Singletons that captured the old `userId` at init (MockChatService,
    // RemoteChatService) won't pick up the new id until the next process
    // launch — the debug button calls this and then `exit(0)` to force a
    // clean restart.
    func resetLocalIdentity() {
        let defaults = UserDefaults.standard

        defaults.removeObject(forKey: Keys.userId)
        defaults.removeObject(forKey: Keys.username)
        defaults.removeObject(forKey: Keys.avatarEmoji)
        defaults.removeObject(forKey: Keys.avatarImageData)
        defaults.removeObject(forKey: Keys.avatarColorHex)
        defaults.removeObject(forKey: Keys.bio)
        defaults.removeObject(forKey: Keys.socialTwitter)
        defaults.removeObject(forKey: Keys.socialInstagram)
        defaults.removeObject(forKey: Keys.socialTikTok)
        defaults.removeObject(forKey: Keys.appleUserId)
        defaults.removeObject(forKey: Keys.appleEmail)

        // Re-seed live @Published properties so any subscribers see the
        // reset state in this process before exit.
        let newId = UUID()
        defaults.set(newId.uuidString, forKey: Keys.userId)
        self.userId = newId
        self.username = ""
        self.avatarEmoji = AvatarEmojis.random
        self.avatarImageData = nil
        self.avatarColorHex = "#00D9FF"
        self.bio = ""
        self.socialTwitter = ""
        self.socialInstagram = ""
        self.socialTikTok = ""
        self.appleUserId = nil
        self.appleEmail = nil
    }
    #endif

    // MARK: - Blocking
    func blockUser(_ userId: UUID) {
        blockedUserIds.insert(userId)
    }

    func unblockUser(_ userId: UUID) {
        blockedUserIds.remove(userId)
    }

    func isBlocked(_ userId: UUID) -> Bool {
        blockedUserIds.contains(userId)
    }

    // MARK: - Authentication
    func setAppleSignIn(userId: String, email: String?) {
        self.appleUserId = userId
        self.appleEmail = email
    }

    func clearAppleSignIn() {
        self.appleUserId = nil
        self.appleEmail = nil
    }

    // MARK: - Onboarding
    func completeOnboarding() {
        hasCompletedOnboarding = true
    }

    func resetOnboarding() {
        hasCompletedOnboarding = false
        followedTeamIds = []
        username = ""
        avatarEmoji = AvatarEmojis.random
        avatarImageData = nil
        avatarColorHex = "#00D9FF"
        bio = ""
        socialTwitter = ""
        socialInstagram = ""
        socialTikTok = ""
    }

    func signOut() {
        // Clear all user data
        hasCompletedOnboarding = false
        followedTeamIds = []
        username = ""
        avatarEmoji = AvatarEmojis.random
        avatarImageData = nil
        avatarColorHex = "#00D9FF"
        bio = ""
        socialTwitter = ""
        socialInstagram = ""
        socialTikTok = ""
        blockedUserIds = []
        appleUserId = nil
        appleEmail = nil

        // Generate new anonymous user ID
        let newId = UUID()
        userId = newId
        UserDefaults.standard.set(newId.uuidString, forKey: Keys.userId)
    }

    // MARK: - Persistence
    private func save() {
        UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding)

        if let data = try? JSONEncoder().encode(followedTeamIds) {
            UserDefaults.standard.set(data, forKey: Keys.followedTeamIds)
        }

        if let data = try? JSONEncoder().encode(blockedUserIds) {
            UserDefaults.standard.set(data, forKey: Keys.blockedUserIds)
        }

        UserDefaults.standard.set(username, forKey: Keys.username)
        UserDefaults.standard.set(avatarEmoji, forKey: Keys.avatarEmoji)
        UserDefaults.standard.set(avatarColorHex, forKey: Keys.avatarColorHex)
        UserDefaults.standard.set(bio, forKey: Keys.bio)
        UserDefaults.standard.set(socialTwitter, forKey: Keys.socialTwitter)
        UserDefaults.standard.set(socialInstagram, forKey: Keys.socialInstagram)
        UserDefaults.standard.set(socialTikTok, forKey: Keys.socialTikTok)

        if let avatarImageData = avatarImageData {
            UserDefaults.standard.set(avatarImageData, forKey: Keys.avatarImageData)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.avatarImageData)
        }

        if let appleUserId = appleUserId {
            UserDefaults.standard.set(appleUserId, forKey: Keys.appleUserId)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.appleUserId)
        }

        if let appleEmail = appleEmail {
            UserDefaults.standard.set(appleEmail, forKey: Keys.appleEmail)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.appleEmail)
        }
    }
}
