import SwiftUI

struct TeamsListView: View {
    @ObservedObject var preferences: UserPreferences
    @Binding var selectedTab: Int
    @State private var selectedLeague: League = .nfl
    @State private var searchText = ""
    @State private var selectedTeam: SportsTeam?
    @FocusState private var isSearchFocused: Bool

    private var allLeagueTeams: [SportsTeam] {
        let leagueTeams = TeamDatabase.teams(for: selectedLeague)

        if searchText.isEmpty {
            return leagueTeams
        }

        return leagueTeams.filter { team in
            team.fullName.localizedCaseInsensitiveContains(searchText) ||
            team.shortName.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Followed teams in the current league (filtered by search)
    private var followedTeamsInLeague: [SportsTeam] {
        allLeagueTeams.filter { preferences.isFollowing($0) }
    }

    /// Unfollowed teams in the current league (filtered by search)
    private var unfollowedTeamsInLeague: [SportsTeam] {
        allLeagueTeams.filter { !preferences.isFollowing($0) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Dark background
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                NoiseBackground()
                    .opacity(0.3)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // League tabs (at the top, safe area respected)
                    leagueTabs
                        .padding(.top, 8)

                    // Search bar
                    searchBar

                    // Teams list
                    teamsList
                }
            }
            .navigationBarHidden(true)
            .navigationDestination(isPresented: Binding(
                get: { selectedTeam != nil },
                set: { if !$0 { selectedTeam = nil } }
            )) {
                if let team = selectedTeam {
                    TeamPageView(team: team)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: selectedTab) { _, newTab in
            if newTab == 1 {
                selectedTeam = nil
            }
        }
    }

    // MARK: - League Tabs
    private var leagueTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(League.allCases) { league in
                    Button {
                        selectedTeam = nil  // Clear stale navigation state
                        withAnimation(AnimationConfig.snappy) {
                            selectedLeague = league
                        }
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: league.icon)
                                .font(.system(size: 14, weight: .semibold))

                            Text(league.displayName)
                                .font(.system(size: 14, weight: .bold))
                        }
                        .foregroundColor(selectedLeague == league ? .white : FanChatTheme.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(selectedLeague == league ?
                                      AnyShapeStyle(LinearGradient(colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink], startPoint: .leading, endPoint: .trailing)) :
                                      AnyShapeStyle(FanChatTheme.backgroundSecondary))
                        )
                        .overlay(
                            Capsule()
                                .stroke(selectedLeague == league ? Color.clear : FanChatTheme.backgroundTertiary, lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Search Bar
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(FanChatTheme.textTertiary)

            TextField("Search teams...", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundColor(FanChatTheme.textPrimary)
                .focused($isSearchFocused)

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
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Teams List
    private var teamsList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                // FOLLOWING section
                if !followedTeamsInLeague.isEmpty {
                    HStack {
                        Text("FOLLOWING")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(FanChatTheme.neonGreen)
                            .tracking(2)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    ForEach(followedTeamsInLeague) { team in
                        teamRow(team)
                    }
                }

                // ALL TEAMS section
                HStack {
                    Text("ALL \(selectedLeague.displayName.uppercased()) TEAMS")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(FanChatTheme.textTertiary)
                        .tracking(2)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, followedTeamsInLeague.isEmpty ? 8 : 16)

                ForEach(unfollowedTeamsInLeague) { team in
                    teamRow(team)
                }
            }
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Each team row: navigation zone on the left, follow button on the right
    @ViewBuilder
    private func teamRow(_ team: SportsTeam) -> some View {
        TeamRowView(
            team: team,
            preferences: preferences,
            onNavigate: {
                isSearchFocused = false
                selectedTeam = team
            }
        )
    }
}

/// Separate View struct so @ObservedObject properly triggers re-renders for icon state
struct TeamRowView: View {
    let team: SportsTeam
    @ObservedObject var preferences: UserPreferences
    let onNavigate: () -> Void

    var body: some View {
        let isFollowed = preferences.isFollowing(team)

        HStack(spacing: 0) {
            // LEFT ZONE: tappable for navigation
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [team.primaryColor, team.secondaryColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)

                    Text(team.logoEmoji)
                        .font(.system(size: 26))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(team.fullName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(FanChatTheme.textPrimary)

                    Text(team.shortName)
                        .font(.system(size: 13))
                        .foregroundColor(FanChatTheme.textTertiary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onNavigate()
            }

            // RIGHT ZONE: follow toggle
            Button {
                print("🟢 FOLLOW BUTTON TAPPED for \(team.fullName)")
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                preferences.toggleTeam(team)
            } label: {
                Image(systemName: isFollowed ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 26))
                    .foregroundColor(isFollowed ? FanChatTheme.neonGreen : FanChatTheme.neonBlue)
                    .frame(width: 50, height: 50)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(FanChatTheme.textTertiary)
                .onTapGesture {
                    onNavigate()
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFollowed ? FanChatTheme.cardBackgroundElevated : FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isFollowed ? team.primaryColor.opacity(0.3) : FanChatTheme.backgroundTertiary, lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}

#Preview {
    TeamsListView(preferences: UserPreferences.shared, selectedTab: .constant(1))
}
