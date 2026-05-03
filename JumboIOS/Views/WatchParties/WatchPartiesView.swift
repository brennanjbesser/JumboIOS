import SwiftUI
import Combine

// MARK: - Watch Parties tab root

struct WatchPartiesView: View {
    @StateObject private var viewModel = WatchPartiesViewModel()
    @State private var showingCreate = false
    @State private var showingJoin = false
    @State private var selectedParty: WatchParty?

    var body: some View {
        NavigationStack {
            ZStack {
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                NoiseBackground()
                    .opacity(0.3)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    header

                    ScrollView {
                        VStack(spacing: 14) {
                            actionsRow
                                .padding(.top, 14)

                            if viewModel.parties.isEmpty {
                                emptyState
                                    .padding(.top, 40)
                            } else {
                                ForEach(viewModel.parties) { party in
                                    WatchPartyRow(
                                        party: party,
                                        liveGame: viewModel.liveGame(for: party),
                                        onTap: { selectedParty = party }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 120)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(item: $selectedParty) { party in
                WatchPartyChatView(partyId: party.id)
            }
            .sheet(isPresented: $showingCreate) {
                CreateWatchPartyView { newParty in
                    selectedParty = newParty
                }
                .presentationBackground(FanChatTheme.backgroundPrimary)
            }
            .sheet(isPresented: $showingJoin) {
                JoinWatchPartySheet { joinedParty in
                    selectedParty = joinedParty
                }
                .presentationDetents([.medium])
                .presentationBackground(FanChatTheme.backgroundPrimary)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PRIVATE")
                .font(.system(size: 11, weight: .black))
                .tracking(2)
                .foregroundColor(FanChatTheme.textTertiary)

            Text("Watch Parties")
                .font(.system(size: 28, weight: .black))
                .foregroundColor(FanChatTheme.textPrimary)

            Text("Watch and react together with your friends.")
                .font(.system(size: 13))
                .foregroundColor(FanChatTheme.textSecondary)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(FanChatTheme.backgroundPrimary)
    }

    // MARK: - Actions row

    private var actionsRow: some View {
        HStack(spacing: 10) {
            Button {
                let g = UIImpactFeedbackGenerator(style: .light)
                g.impactOccurred()
                showingCreate = true
            } label: {
                actionLabel(icon: "plus.circle.fill", title: "Create Party", primary: true)
            }

            Button {
                let g = UIImpactFeedbackGenerator(style: .light)
                g.impactOccurred()
                showingJoin = true
            } label: {
                actionLabel(icon: "key.fill", title: "Join with Code", primary: false)
            }
        }
    }

    private func actionLabel(icon: String, title: String, primary: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
            Text(title)
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundColor(primary ? .white : FanChatTheme.textPrimary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(
                    primary
                    ? AnyShapeStyle(LinearGradient(
                        colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    : AnyShapeStyle(FanChatTheme.backgroundTertiary)
                )
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(primary ? 0 : 0.10), lineWidth: 0.5)
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.3.sequence.fill")
                .font(.system(size: 48))
                .foregroundColor(FanChatTheme.textTertiary)

            Text("No watch parties yet")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(FanChatTheme.textPrimary)

            Text("Create a room and invite friends to watch a live game together.")
                .font(.system(size: 14))
                .foregroundColor(FanChatTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

struct WatchPartyRow: View {
    let party: WatchParty
    let liveGame: LiveGame?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // Top: name + member count
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(badgeFill)
                            .frame(width: 38, height: 38)

                        Image(systemName: liveGame == nil ? "bubble.left.and.bubble.right.fill" : "tv.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(party.name)
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundColor(FanChatTheme.textPrimary)
                            .lineLimit(1)

                        HStack(spacing: 8) {
                            HStack(spacing: 4) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(party.memberIds.count)")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(FanChatTheme.textSecondary)

                            Text("•")
                                .foregroundColor(FanChatTheme.textTertiary)

                            Text(party.inviteCode)
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .tracking(1)
                                .foregroundColor(FanChatTheme.textTertiary)
                        }
                    }

                    Spacer()

                    if liveGame != nil {
                        HStack(spacing: 4) {
                            LivePulseIndicator(animated: true)
                            Text("LIVE")
                                .font(.system(size: 10, weight: .black))
                                .tracking(1.2)
                                .foregroundColor(FanChatTheme.liveIndicator)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                if let game = liveGame {
                    Divider()
                        .background(FanChatTheme.backgroundTertiary)
                    gameStrip(game)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(FanChatTheme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var badgeFill: LinearGradient {
        if let game = liveGame {
            return LinearGradient(
                colors: [game.awayTeam.primaryColor, game.homeTeam.primaryColor],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func gameStrip(_ game: LiveGame) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(game.awayTeam.logoEmoji).font(.system(size: 14))
                Text(game.awayTeam.shortName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(FanChatTheme.textSecondary)
                Text("\(game.awayScore)")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(FanChatTheme.textPrimary)
            }

            Spacer()

            VStack(spacing: 1) {
                if game.status == .halftime {
                    Text("HALF")
                        .font(.system(size: 10, weight: .black))
                        .foregroundColor(FanChatTheme.textPrimary)
                } else {
                    if !game.timeRemaining.isEmpty {
                        Text(game.timeRemaining)
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundColor(FanChatTheme.textPrimary)
                    }
                    Text(game.period)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(FanChatTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Text("\(game.homeScore)")
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .foregroundColor(FanChatTheme.textPrimary)
                Text(game.homeTeam.shortName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(FanChatTheme.textSecondary)
                Text(game.homeTeam.logoEmoji).font(.system(size: 14))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Join sheet (small)

struct JoinWatchPartySheet: View {
    var onJoined: (WatchParty) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var code: String = ""
    @State private var error: String?

    // Backed by `AppServices.shared.watchPartyService` — see AppServices.swift.
    private let service: any WatchPartyServiceProtocol = AppServices.shared.watchPartyService

    var body: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(FanChatTheme.backgroundTertiary)
                .frame(width: 36, height: 4)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                Text("JOIN WITH CODE")
                    .font(.system(size: 11, weight: .black))
                    .tracking(2)
                    .foregroundColor(FanChatTheme.textTertiary)

                Text("Enter your invite code")
                    .font(.system(size: 22, weight: .black))
                    .foregroundColor(FanChatTheme.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 8)

            TextField("CODE", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 22, weight: .black, design: .monospaced))
                .tracking(3)
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(FanChatTheme.backgroundSecondary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
                )
                .padding(.horizontal, 20)

            if let error {
                Text(error)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FanChatTheme.liveIndicator)
            }

            Spacer()

            Button {
                attemptJoin()
            } label: {
                Text("Join Party")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule()
                            .fill(LinearGradient(
                                colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                                startPoint: .leading, endPoint: .trailing
                            ))
                    )
            }
            .disabled(code.count < 4)
            .opacity(code.count < 4 ? 0.5 : 1)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func attemptJoin() {
        guard let party = service.party(byInviteCode: code) else {
            error = "No party found with that code."
            return
        }
        if let updated = service.join(partyId: party.id, userId: UserPreferences.shared.userId) {
            dismiss()
            // Slight delay so the dismiss animation runs first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                onJoined(updated)
            }
        }
    }
}

// MARK: - View Model

@MainActor
final class WatchPartiesViewModel: ObservableObject {
    @Published private(set) var parties: [WatchParty] = []

    private var liveGames: [LiveGame] = []
    private var cancellables = Set<AnyCancellable>()

    // Backed by `AppServices.shared.watchPartyService` — see AppServices.swift.
    private let service: any WatchPartyServiceProtocol = AppServices.shared.watchPartyService

    init() {
        let me = UserPreferences.shared.userId

        service.partiesPublisher
            .receive(on: DispatchQueue.main)
            .map { all in
                all.filter { $0.memberIds.contains(me) }
                   .sorted { $0.createdAt > $1.createdAt }
            }
            .assign(to: &$parties)

        LiveScoreService.shared.$liveGames
            .receive(on: DispatchQueue.main)
            .sink { [weak self] games in
                self?.liveGames = games
                // Re-emit so rows re-render with the latest scores.
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func liveGame(for party: WatchParty) -> LiveGame? {
        guard let gid = party.gameId else { return nil }
        return liveGames.first { $0.id == gid }
    }
}
