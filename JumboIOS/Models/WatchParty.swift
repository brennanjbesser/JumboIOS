import Foundation

// MARK: - Watch Party (private group chat room)
//
// A WatchParty is a private group chat tied (optionally) to a specific live
// game. The "watch together" feel comes from anchoring the room to a game so
// the live scoreboard pins to the top of the chat and members react in real
// time to the same play.

struct WatchParty: Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    let creatorId: UUID
    /// `LiveGame.id` of the game this party is tied to. Nil means "general"
    /// (not tied to any game).
    var gameId: UUID?
    var memberIds: Set<UUID>
    let createdAt: Date
    /// Six-character invite code displayed in the UI (e.g. "JUMBO7").
    let inviteCode: String

    init(
        id: UUID = UUID(),
        name: String,
        creatorId: UUID,
        gameId: UUID? = nil,
        memberIds: Set<UUID> = [],
        createdAt: Date = Date(),
        inviteCode: String = WatchParty.generateInviteCode()
    ) {
        self.id = id
        self.name = name
        self.creatorId = creatorId
        self.gameId = gameId
        // Always include the creator as a member.
        var members = memberIds
        members.insert(creatorId)
        self.memberIds = members
        self.createdAt = createdAt
        self.inviteCode = inviteCode
    }

    static func generateInviteCode() -> String {
        let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // no I/O/0/1
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

// MARK: - Message in a watch party

struct WatchPartyMessage: Identifiable, Equatable, Hashable {
    let id: UUID
    let partyId: UUID
    let authorId: UUID
    let content: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        partyId: UUID,
        authorId: UUID,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.partyId = partyId
        self.authorId = authorId
        self.content = content
        self.createdAt = createdAt
    }
}

// MARK: - Lightweight member info for member list rendering

struct WatchPartyMember: Identifiable, Equatable, Hashable {
    let id: UUID         // userId
    let displayName: String
    let avatarEmoji: String
    let avatarColorHex: String
    let isCreator: Bool
}
