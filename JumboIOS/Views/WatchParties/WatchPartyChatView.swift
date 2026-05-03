import SwiftUI
import Combine

struct WatchPartyChatView: View {
    let partyId: UUID

    @StateObject private var viewModel: WatchPartyChatViewModel
    @State private var draft: String = ""
    @State private var showingInviteSheet = false
    @FocusState private var composerFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(partyId: UUID) {
        self.partyId = partyId
        self._viewModel = StateObject(wrappedValue: WatchPartyChatViewModel(partyId: partyId))
    }

    var body: some View {
        ZStack {
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            NoiseBackground()
                .opacity(0.3)
                .ignoresSafeArea()

            if let party = viewModel.party {
                VStack(spacing: 0) {
                    headerSection(party: party)
                    messagesList
                    composer
                }
            } else {
                missingPartyView
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(viewModel.party?.name ?? "Watch Party")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(FanChatTheme.textPrimary)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingInviteSheet = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .foregroundColor(FanChatTheme.neonOrange)
                }
            }
        }
        .sheet(isPresented: $showingInviteSheet) {
            if let party = viewModel.party {
                InviteSheet(party: party)
                    .presentationDetents([.medium])
                    .presentationBackground(FanChatTheme.backgroundPrimary)
            }
        }
        .onAppear {
            // Boost live-score polling while a watch party is open if it's
            // tied to a live game — same pattern as the team game room.
            if viewModel.party?.gameId != nil {
                LiveScoreService.shared.boostPolling()
            }
        }
        .onDisappear {
            if viewModel.party?.gameId != nil {
                LiveScoreService.shared.restoreDefaultPolling()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header section (identity + scoreboard if live)

    private func headerSection(party: WatchParty) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(badgeFill)
                        .frame(width: 32, height: 32)
                    Image(systemName: viewModel.liveGame == nil ? "bubble.left.and.bubble.right.fill" : "tv.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(party.inviteCode)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.4)
                        .foregroundColor(FanChatTheme.textTertiary)
                    Text("\(party.memberIds.count) member\(party.memberIds.count == 1 ? "" : "s")")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FanChatTheme.textPrimary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if let game = viewModel.liveGame {
                CasinoTeamLiveGameBanner(game: game, team: game.homeTeam)
                    .padding(.bottom, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .background(FanChatTheme.backgroundSecondary)
        .overlay(
            Rectangle()
                .fill(FanChatTheme.backgroundTertiary)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private var badgeFill: LinearGradient {
        if let game = viewModel.liveGame {
            return LinearGradient(
                colors: [game.awayTeam.primaryColor, game.homeTeam.primaryColor],
                startPoint: .leading, endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // MARK: - Messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if viewModel.messages.isEmpty {
                        emptyChat
                            .padding(.top, 40)
                    } else {
                        ForEach(viewModel.messages) { msg in
                            MessageBubble(
                                message: msg,
                                isMe: msg.authorId == UserPreferences.shared.userId
                            )
                            .id(msg.id)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            .onChange(of: viewModel.messages.count) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyChat: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundColor(FanChatTheme.textTertiary)
            Text("No messages yet")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(FanChatTheme.textSecondary)
            Text("Be the first to react!")
                .font(.system(size: 12))
                .foregroundColor(FanChatTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Send a message…", text: $draft, axis: .vertical)
                .focused($composerFocused)
                .lineLimit(1...4)
                .font(.system(size: 15))
                .foregroundColor(FanChatTheme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(FanChatTheme.backgroundSecondary)
                )
                .overlay(
                    Capsule().stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
                )

            Button {
                send()
            } label: {
                ZStack {
                    Circle()
                        .fill(canSend
                              ? AnyShapeStyle(LinearGradient(
                                    colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                              ))
                              : AnyShapeStyle(FanChatTheme.backgroundTertiary))
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(FanChatTheme.backgroundSecondary)
        .overlay(
            Rectangle()
                .fill(FanChatTheme.backgroundTertiary)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        viewModel.send(draft)
        draft = ""
    }

    // MARK: - Missing party (e.g. left from another device)

    private var missingPartyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 36))
                .foregroundColor(FanChatTheme.textTertiary)
            Text("Party unavailable")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(FanChatTheme.textPrimary)
            Button("Back") { dismiss() }
                .foregroundColor(FanChatTheme.neonOrange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Message bubble

private struct MessageBubble: View {
    let message: WatchPartyMessage
    let isMe: Bool

    var body: some View {
        HStack {
            if isMe { Spacer(minLength: 40) }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 2) {
                Text(message.content)
                    .font(.system(size: 15))
                    .foregroundColor(isMe ? .white : FanChatTheme.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(isMe
                                  ? AnyShapeStyle(LinearGradient(
                                        colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                  ))
                                  : AnyShapeStyle(FanChatTheme.backgroundSecondary))
                    )

                Text(formatTime(message.createdAt))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(FanChatTheme.textTertiary)
                    .padding(.horizontal, 6)
            }

            if !isMe { Spacer(minLength: 40) }
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Invite sheet

private struct InviteSheet: View {
    let party: WatchParty

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(FanChatTheme.backgroundTertiary)
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            VStack(spacing: 6) {
                Text("INVITE FRIENDS")
                    .font(.system(size: 11, weight: .black))
                    .tracking(2)
                    .foregroundColor(FanChatTheme.textTertiary)
                Text(party.name)
                    .font(.system(size: 20, weight: .black))
                    .foregroundColor(FanChatTheme.textPrimary)
            }

            HStack(spacing: 12) {
                Text(party.inviteCode)
                    .font(.system(size: 28, weight: .black, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(FanChatTheme.textPrimary)

                Button {
                    UIPasteboard.general.string = party.inviteCode
                    let g = UINotificationFeedbackGenerator()
                    g.notificationOccurred(.success)
                } label: {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(FanChatTheme.neonOrange)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(FanChatTheme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
            )

            ShareLink(item: "Join my JUMBO watch party \"\(party.name)\". Code: \(party.inviteCode)") {
                Text("Share Invite")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                            startPoint: .leading, endPoint: .trailing
                        ))
                    )
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .padding(.bottom, 24)
    }
}

// MARK: - View Model

@MainActor
final class WatchPartyChatViewModel: ObservableObject {
    @Published private(set) var party: WatchParty?
    @Published private(set) var messages: [WatchPartyMessage] = []
    @Published private(set) var liveGame: LiveGame?

    private let partyId: UUID
    // Backed by `AppServices.shared.watchPartyService` — see AppServices.swift.
    private let service: any WatchPartyServiceProtocol = AppServices.shared.watchPartyService
    private var cancellables = Set<AnyCancellable>()

    init(partyId: UUID) {
        self.partyId = partyId

        // Party (re-resolve when the parties list changes)
        service.partiesPublisher
            .receive(on: DispatchQueue.main)
            .map { $0.first { $0.id == partyId } }
            .assign(to: &$party)

        // Messages
        service.messagesPublisher(for: partyId)
            .receive(on: DispatchQueue.main)
            .assign(to: &$messages)

        // Live game (re-resolves when the party's gameId or live snapshot changes)
        Publishers.CombineLatest($party, LiveScoreService.shared.$liveGames)
            .map { p, games -> LiveGame? in
                guard let gid = p?.gameId else { return nil }
                let match = games.first { $0.id == gid }
                // Drop the scoreboard once the game ends.
                return (match?.status.isActive ?? false) ? match : nil
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .assign(to: &$liveGame)
    }

    func send(_ content: String) {
        let me = UserPreferences.shared.userId
        _ = service.sendMessage(to: partyId, authorId: me, content: content)
    }
}
