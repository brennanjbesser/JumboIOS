import SwiftUI
import Combine

struct CreateWatchPartyView: View {
    var onCreated: (WatchParty) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = CreateWatchPartyViewModel()

    @State private var name: String = ""
    @State private var selectedGameId: UUID? = nil
    @State private var createdParty: WatchParty?
    @FocusState private var nameFieldFocused: Bool

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                if let party = createdParty {
                    successView(party: party)
                } else {
                    formView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(FanChatTheme.textSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(createdParty == nil ? "New Watch Party" : "Party Created")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(FanChatTheme.textPrimary)
                }
            }
            .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Form

    private var formView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Name
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Party Name")
                    TextField("e.g. Sunday Squad", text: $name)
                        .focused($nameFieldFocused)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(FanChatTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(FanChatTheme.backgroundSecondary)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
                        )
                }

                // Game tie
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Tie to a live game (optional)")

                    if viewModel.liveGames.isEmpty {
                        emptyGamesNote
                    } else {
                        VStack(spacing: 8) {
                            generalOptionRow

                            ForEach(viewModel.liveGames) { game in
                                gameOptionRow(game)
                            }
                        }
                    }
                }

                Spacer(minLength: 40)

                // Create CTA
                Button {
                    create()
                } label: {
                    Text("Create Party")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule().fill(LinearGradient(
                                colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                                startPoint: .leading, endPoint: .trailing
                            ))
                        )
                }
                .disabled(!canCreate)
                .opacity(canCreate ? 1 : 0.5)
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .onAppear { nameFieldFocused = true }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .black))
            .tracking(1.4)
            .foregroundColor(FanChatTheme.textTertiary)
    }

    private var emptyGamesNote: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .foregroundColor(FanChatTheme.textTertiary)
            Text("No live games right now. You can still create a general room.")
                .font(.system(size: 13))
                .foregroundColor(FanChatTheme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
        )
    }

    private var generalOptionRow: some View {
        Button {
            selectedGameId = nil
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(FanChatTheme.backgroundTertiary).frame(width: 36, height: 36)
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 14))
                        .foregroundColor(FanChatTheme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("General room")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundColor(FanChatTheme.textPrimary)
                    Text("Not tied to a game")
                        .font(.system(size: 11))
                        .foregroundColor(FanChatTheme.textTertiary)
                }

                Spacer()

                selectionIndicator(isSelected: selectedGameId == nil)
            }
            .padding(12)
            .background(rowBackground(isSelected: selectedGameId == nil))
        }
        .buttonStyle(.plain)
    }

    private func gameOptionRow(_ game: LiveGame) -> some View {
        Button {
            selectedGameId = game.id
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [game.awayTeam.primaryColor, game.homeTeam.primaryColor],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: 36, height: 36)
                    Image(systemName: "tv.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(game.awayTeam.shortName) \(game.awayScore)")
                        Text("@")
                            .foregroundColor(FanChatTheme.textTertiary)
                        Text("\(game.homeTeam.shortName) \(game.homeScore)")
                    }
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(FanChatTheme.textPrimary)

                    HStack(spacing: 6) {
                        LivePulseIndicator(animated: false)
                        Text("LIVE")
                            .foregroundColor(FanChatTheme.liveIndicator)
                        if !game.timeRemaining.isEmpty {
                            Text("• \(game.timeRemaining) \(game.period)")
                                .foregroundColor(FanChatTheme.textTertiary)
                        }
                    }
                    .font(.system(size: 10, weight: .bold))
                }

                Spacer()

                selectionIndicator(isSelected: selectedGameId == game.id)
            }
            .padding(12)
            .background(rowBackground(isSelected: selectedGameId == game.id))
        }
        .buttonStyle(.plain)
    }

    private func selectionIndicator(isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1.5)
                .frame(width: 22, height: 22)
            if isSelected {
                Circle()
                    .fill(FanChatTheme.neonOrange)
                    .frame(width: 14, height: 14)
            }
        }
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(FanChatTheme.backgroundSecondary)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? FanChatTheme.neonOrange : FanChatTheme.backgroundTertiary, lineWidth: isSelected ? 1.5 : 1)
            )
    }

    // MARK: - Success view (shows invite code + Open CTA)

    private func successView(party: WatchParty) -> some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 84, height: 84)
                Image(systemName: "party.popper.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(spacing: 6) {
                Text(party.name)
                    .font(.system(size: 22, weight: .black))
                    .foregroundColor(FanChatTheme.textPrimary)
                Text("Share this code with your friends to invite them")
                    .font(.system(size: 13))
                    .foregroundColor(FanChatTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }

            // Invite code chip
            HStack(spacing: 12) {
                Text(party.inviteCode)
                    .font(.system(size: 26, weight: .black, design: .monospaced))
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

            Spacer()

            VStack(spacing: 10) {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        onCreated(party)
                    }
                } label: {
                    Text("Open Party")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            Capsule().fill(LinearGradient(
                                colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                                startPoint: .leading, endPoint: .trailing
                            ))
                        )
                }

                ShareLink(item: shareMessage(for: party)) {
                    Text("Share Invite")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(FanChatTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Capsule().fill(FanChatTheme.backgroundTertiary)
                        )
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private func shareMessage(for party: WatchParty) -> String {
        "Join my JUMBO watch party \"\(party.name)\". Code: \(party.inviteCode)"
    }

    // MARK: - Create

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Goes through AppServices so this view picks up RemoteWatchPartyService
        // automatically once it ships — no edit here required.
        let party = AppServices.shared.watchPartyService.createParty(
            name: trimmed,
            gameId: selectedGameId,
            creatorId: UserPreferences.shared.userId
        )
        let g = UINotificationFeedbackGenerator()
        g.notificationOccurred(.success)
        createdParty = party
    }
}

// MARK: - View Model

@MainActor
final class CreateWatchPartyViewModel: ObservableObject {
    @Published private(set) var liveGames: [LiveGame] = []

    init() {
        LiveScoreService.shared.$liveGames
            .receive(on: DispatchQueue.main)
            .map { $0.filter { $0.status.isActive } }
            .assign(to: &$liveGames)
    }
}
