import SwiftUI

struct TeamSelectionView: View {
    @ObservedObject var preferences: UserPreferences
    let onComplete: () -> Void

    @State private var selectedLeague: League = .nfl
    @State private var searchText = ""
    @State private var showMaxTeamsAlert = false

    private var filteredTeams: [SportsTeam] {
        let leagueTeams = TeamDatabase.teams(for: selectedLeague)

        if searchText.isEmpty {
            return leagueTeams
        }

        return leagueTeams.filter { team in
            team.fullName.localizedCaseInsensitiveContains(searchText) ||
            team.shortName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        ZStack {
            // Dark background
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            NoiseBackground()
                .opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                headerView

                // League tabs
                leagueTabs

                // Search bar
                searchBar

                // Teams grid
                teamsGrid

                // Bottom bar with continue button
                bottomBar
            }
        }
        .preferredColorScheme(.dark)
        .alert("Maximum Teams Reached", isPresented: $showMaxTeamsAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("You can follow up to \(UserPreferences.maxTeamsAllowed) teams. Unfollow a team to add another.")
        }
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(spacing: 10) {
            Text("Pick Your Teams")
                .font(.system(size: 30, weight: .black))
                .foregroundColor(FanChatTheme.textPrimary)

            Text("Select \(UserPreferences.minTeamsRequired)-\(UserPreferences.maxTeamsAllowed) teams to follow")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(FanChatTheme.textSecondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - League Tabs
    private var leagueTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(League.allCases) { league in
                    CasinoLeagueTab(
                        league: league,
                        isSelected: selectedLeague == league,
                        followedCount: preferences.followedTeams.filter { $0.league == league }.count
                    ) {
                        withAnimation(AnimationConfig.snappy) {
                            selectedLeague = league
                        }
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 12)
    }

    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(FanChatTheme.textTertiary)

            TextField("Search teams...", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundColor(FanChatTheme.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(FanChatTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Teams Grid
    private var teamsGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ],
                spacing: 12
            ) {
                ForEach(filteredTeams) { team in
                    CasinoTeamCard(
                        team: team,
                        isSelected: preferences.isFollowing(team)
                    ) {
                        toggleTeam(team)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 120)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Bottom Bar
    private var bottomBar: some View {
        VStack(spacing: 14) {
            // Selection counter with neon dots
            HStack {
                Text("\(preferences.followedTeamIds.count) of \(UserPreferences.maxTeamsAllowed) teams selected")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(FanChatTheme.textSecondary)

                Spacer()

                // Selection dots with glow
                HStack(spacing: 6) {
                    ForEach(0..<UserPreferences.minTeamsRequired, id: \.self) { index in
                        Circle()
                            .fill(index < preferences.followedTeamIds.count ? FanChatTheme.neonGreen : FanChatTheme.backgroundTertiary)
                            .frame(width: 10, height: 10)
                            .glow(FanChatTheme.neonGreen, radius: 4, isActive: index < preferences.followedTeamIds.count)
                    }
                }
            }

            // Continue button with neon glow
            Button(action: {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                preferences.completeOnboarding()
                onComplete()
            }) {
                HStack(spacing: 10) {
                    Text(preferences.canProceedFromOnboarding ? "Continue" : "Select \(UserPreferences.minTeamsRequired - preferences.followedTeamIds.count) more")
                        .font(.system(size: 17, weight: .bold))

                    if preferences.canProceedFromOnboarding {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(preferences.canProceedFromOnboarding ?
                              AnyShapeStyle(LinearGradient(colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink], startPoint: .leading, endPoint: .trailing)) :
                              AnyShapeStyle(FanChatTheme.backgroundTertiary))
                )
                .glow(FanChatTheme.neonOrange, radius: 12, isActive: preferences.canProceedFromOnboarding)
            }
            .disabled(!preferences.canProceedFromOnboarding)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            FanChatTheme.backgroundSecondary
                .overlay(
                    Rectangle()
                        .fill(FanChatTheme.backgroundTertiary)
                        .frame(height: 0.5),
                    alignment: .top
                )
        )
    }

    // MARK: - Actions
    private func toggleTeam(_ team: SportsTeam) {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        if preferences.isFollowing(team) {
            preferences.unfollowTeam(team)
        } else {
            if preferences.followedTeamIds.count >= UserPreferences.maxTeamsAllowed {
                showMaxTeamsAlert = true
            } else {
                preferences.followTeam(team)
            }
        }
    }
}

// MARK: - Casino League Tab
struct CasinoLeagueTab: View {
    let league: League
    let isSelected: Bool
    let followedCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: league.icon)
                    .font(.system(size: 16, weight: .semibold))

                Text(league.displayName)
                    .font(.system(size: 15, weight: .bold))

                if followedCount > 0 {
                    Text("\(followedCount)")
                        .font(.system(size: 12, weight: .black))
                        .foregroundColor(isSelected ? .white : FanChatTheme.neonGreen)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.25) : FanChatTheme.neonGreen.opacity(0.2))
                        )
                        .glow(FanChatTheme.neonGreen, radius: 4, isActive: !isSelected && followedCount > 0)
                }
            }
            .foregroundColor(isSelected ? .white : FanChatTheme.textSecondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(isSelected ?
                          AnyShapeStyle(LinearGradient(colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink], startPoint: .leading, endPoint: .trailing)) :
                          AnyShapeStyle(FanChatTheme.backgroundSecondary))
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : FanChatTheme.backgroundTertiary, lineWidth: 1)
            )
            .glow(FanChatTheme.neonOrange, radius: 8, isActive: isSelected)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Casino Team Card
struct CasinoTeamCard: View {
    let team: SportsTeam
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 14) {
                // Team emoji/logo with glow
                ZStack {
                    // Glow when selected
                    if isSelected {
                        Circle()
                            .fill(team.primaryColor.opacity(0.3))
                            .frame(width: 72, height: 72)
                            .blur(radius: 10)
                    }

                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [team.primaryColor, team.secondaryColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 60, height: 60)
                        .glow(team.primaryColor, radius: 8, isActive: isSelected)

                    Text(team.logoEmoji)
                        .font(.system(size: 30))
                }

                // Team info
                VStack(spacing: 4) {
                    Text(team.city.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(FanChatTheme.textTertiary)
                        .tracking(1)

                    Text(team.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(FanChatTheme.textPrimary)
                        .lineLimit(1)
                }

                // Selection indicator
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(FanChatTheme.neonGreen)
                        .glow(FanChatTheme.neonGreen, radius: 6)
                } else {
                    Circle()
                        .stroke(FanChatTheme.backgroundTertiary, lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isSelected ?
                          FanChatTheme.cardBackgroundElevated :
                          FanChatTheme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(isSelected ? team.primaryColor.opacity(0.6) : FanChatTheme.backgroundTertiary, lineWidth: isSelected ? 2 : 1)
            )
            .glow(team.primaryColor, radius: 10, isActive: isSelected)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.95 : (isSelected ? 1.02 : 1.0))
        .animation(AnimationConfig.snappy, value: isSelected)
        .animation(AnimationConfig.snappy, value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

#Preview {
    TeamSelectionView(preferences: UserPreferences.shared) {
        print("Complete")
    }
}
