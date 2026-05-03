import Foundation
import Combine

// MARK: - Service protocol
//
// All watch-party UI obtains its conformer via `AppServices.shared.watchPartyService`
// and never references `MockWatchPartyService` directly — that's the swap
// point for the upcoming `RemoteWatchPartyService`. Marked @MainActor to
// match the mock's isolation; views and view models are already main-actor.
@MainActor
protocol WatchPartyServiceProtocol: AnyObject {
    var partiesPublisher: AnyPublisher<[WatchParty], Never> { get }
    func parties(for userId: UUID) -> [WatchParty]
    func party(by id: UUID) -> WatchParty?
    func party(byInviteCode code: String) -> WatchParty?

    @discardableResult
    func createParty(name: String, gameId: UUID?, creatorId: UUID) -> WatchParty

    @discardableResult
    func join(partyId: UUID, userId: UUID) -> WatchParty?

    func leave(partyId: UUID, userId: UUID)

    func messagesPublisher(for partyId: UUID) -> AnyPublisher<[WatchPartyMessage], Never>
    func messages(for partyId: UUID) -> [WatchPartyMessage]

    @discardableResult
    func sendMessage(to partyId: UUID, authorId: UUID, content: String) -> WatchPartyMessage?
}

// MARK: - Mock implementation
//
// In-memory store. Seeds two demo parties on first launch so the tab isn't
// empty out of the box. Replace with a real backend by writing another conformer
// to WatchPartyServiceProtocol — call sites only depend on the protocol.

@MainActor
final class MockWatchPartyService: ObservableObject, WatchPartyServiceProtocol {
    static let shared = MockWatchPartyService()

    @Published private var parties: [WatchParty] = []
    @Published private var messagesByParty: [UUID: [WatchPartyMessage]] = [:]

    var partiesPublisher: AnyPublisher<[WatchParty], Never> {
        $parties.eraseToAnyPublisher()
    }

    private init() {
        // Intentionally empty. Mock data must NOT simulate real user activity —
        // no seeded demo parties, no fake members, no fake messages. All real
        // watch parties will come from the backend in the next phase.
    }

    // MARK: - Reads

    func parties(for userId: UUID) -> [WatchParty] {
        parties
            .filter { $0.memberIds.contains(userId) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func party(by id: UUID) -> WatchParty? {
        parties.first { $0.id == id }
    }

    func party(byInviteCode code: String) -> WatchParty? {
        let normalized = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return parties.first { $0.inviteCode == normalized }
    }

    func messages(for partyId: UUID) -> [WatchPartyMessage] {
        messagesByParty[partyId] ?? []
    }

    func messagesPublisher(for partyId: UUID) -> AnyPublisher<[WatchPartyMessage], Never> {
        $messagesByParty
            .map { $0[partyId] ?? [] }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    // MARK: - Writes

    @discardableResult
    func createParty(name: String, gameId: UUID?, creatorId: UUID) -> WatchParty {
        let party = WatchParty(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            creatorId: creatorId,
            gameId: gameId
        )
        parties.insert(party, at: 0)
        messagesByParty[party.id] = []
        return party
    }

    @discardableResult
    func join(partyId: UUID, userId: UUID) -> WatchParty? {
        guard let index = parties.firstIndex(where: { $0.id == partyId }) else { return nil }
        parties[index].memberIds.insert(userId)
        return parties[index]
    }

    func leave(partyId: UUID, userId: UUID) {
        guard let index = parties.firstIndex(where: { $0.id == partyId }) else { return }
        // Creator can't leave their own party in V1 — they can only delete it
        // via a future "delete party" action (not yet wired).
        guard parties[index].creatorId != userId else { return }
        parties[index].memberIds.remove(userId)
    }

    @discardableResult
    func sendMessage(to partyId: UUID, authorId: UUID, content: String) -> WatchPartyMessage? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard parties.contains(where: { $0.id == partyId }) else { return nil }

        let message = WatchPartyMessage(partyId: partyId, authorId: authorId, content: trimmed)
        var existing = messagesByParty[partyId] ?? []
        existing.append(message)
        messagesByParty[partyId] = existing
        return message
    }

}
