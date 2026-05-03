import SwiftUI
import PhotosUI

struct MainTabView: View {
    @ObservedObject var preferences: UserPreferences
    @State private var selectedTab = 0

    // Shared unread-count source of truth. Drives the Alerts tab
    // badge and is cleared optimistically by NotificationsView after
    // markAllAsRead succeeds.
    @ObservedObject private var unreadBadge = UnreadNotificationsBadge.shared

    // Foreground-resume hook — refresh the badge when the app comes
    // back to active so we pick up notifications created while the
    // app was backgrounded.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selectedTab) {
            // Live Games
            LiveGamesView()
                .tabItem {
                    Label("Live", systemImage: "play.tv.fill")
                }
                .tag(0)

            // Teams
            TeamsListView(preferences: preferences, selectedTab: $selectedTab)
                .tabItem {
                    Label("Teams", systemImage: "sportscourt.fill")
                }
                .tag(1)

            // Watch Parties (private group chat rooms)
            WatchPartiesView()
                .tabItem {
                    Label("Parties", systemImage: "person.3.sequence.fill")
                }
                .tag(2)

            // In-app notifications (replies / upvotes)
            NotificationsView()
                .tabItem {
                    Label("Alerts", systemImage: "bell.fill")
                }
                // SwiftUI hides the badge automatically when the
                // value is 0, so passing the raw count is enough —
                // no conditional view-builder needed.
                .badge(unreadBadge.count)
                .tag(3)

            // Settings
            CasinoSettingsView(preferences: preferences)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(4)
        }
        .tint(FanChatTheme.neonOrange)
        .preferredColorScheme(.dark)
        .onAppear {
            // Customize tab bar appearance for dark theme
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(FanChatTheme.backgroundSecondary)
            appearance.stackedLayoutAppearance.normal.iconColor = UIColor(FanChatTheme.textTertiary)
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor(FanChatTheme.textTertiary)]
            appearance.stackedLayoutAppearance.selected.iconColor = UIColor(FanChatTheme.neonOrange)
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(FanChatTheme.neonOrange)]

            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
        // Initial badge fetch + start the app-wide public.users
        // realtime channel so identity edits propagate live to
        // every visible post / reply / notification. Both calls
        // are idempotent so re-runs from the scenePhase hook are
        // safe.
        .task {
            await unreadBadge.refresh()
            await RemoteChatService.shared.startUserProfilesSubscription()
        }
        // Re-fetch + re-arm subscription when the app returns to
        // foreground. The subscription start is a no-op if the
        // channel is still live; it'll re-establish if the channel
        // was dropped while backgrounded.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await unreadBadge.refresh()
                    await RemoteChatService.shared.startUserProfilesSubscription()
                }
            }
        }
    }
}

// MARK: - Casino Settings View
struct CasinoSettingsView: View {
    @ObservedObject var preferences: UserPreferences
    @ObservedObject var authService = AuthenticationService.shared
    @State private var showingResetAlert = false
    @State private var showingSignOutAlert = false
    @State private var showingEditProfile = false

    private var profileGradientPair: (Color, Color) {
        EditProfileSheet.gradientOptions.first(where: { $0.hex == preferences.avatarColorHex })
            .map { ($0.from, $0.to) } ?? (preferences.avatarColor, preferences.avatarColor.opacity(0.5))
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

                ScrollView {
                    VStack(spacing: 20) {
                        // Profile Card
                        profileCard

                        // Followed Teams Section
                        settingsSection(title: "FOLLOWED TEAMS", count: preferences.followedTeams.count) {
                            if preferences.followedTeams.isEmpty {
                                emptyTeamsView
                            } else {
                                ForEach(preferences.followedTeams) { team in
                                    teamRow(team)
                                }
                            }
                        }

                        // Blocked Users Section
                        settingsSection(title: "BLOCKED USERS", count: nil) {
                            if preferences.blockedUserIds.isEmpty {
                                emptyBlockedView
                            } else {
                                blockedUsersRow
                            }
                        }

                        // App Info Section
                        settingsSection(title: "APP INFO", count: nil) {
                            infoRow(title: "Version", value: "1.0.0")
                            infoRow(title: "Anonymous ID", value: String(preferences.userId.uuidString.prefix(8)) + "...")
                        }

                        // Account Section
                        settingsSection(title: "ACCOUNT", count: nil) {
                            signOutButton
                        }

                        // Actions Section
                        settingsSection(title: "ACTIONS", count: nil) {
                            resetButton
                        }

                        // Debug Section — temporary, isolated remote-backend smoke test.
                        // Lives only in Settings so it doesn't affect normal chat routing.
                        #if DEBUG
                        settingsSection(title: "DEBUG", count: nil) {
                            testRemoteVoteButton
                            resetLocalUserButton
                        }
                        #endif

                        // Footer
                        Text("JUMBO v1.0.0")
                            .font(.system(size: 12))
                            .foregroundColor(FanChatTheme.textTertiary)
                            .padding(.top, 20)
                            .padding(.bottom, 40)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Reset Onboarding?", isPresented: $showingResetAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Reset", role: .destructive) {
                    preferences.resetOnboarding()
                }
            } message: {
                Text("This will clear your followed teams and show the welcome screen again.")
            }
            .alert("Sign Out?", isPresented: $showingSignOutAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Sign Out", role: .destructive) {
                    authService.signOut()
                }
            } message: {
                Text("You will need to sign in again to use JUMBO.")
            }
            .sheet(isPresented: $showingEditProfile) {
                EditProfileSheet(preferences: preferences)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Settings Section
    private func settingsSection<Content: View>(title: String, count: Int?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(FanChatTheme.textTertiary)
                    .tracking(2)

                if let count = count {
                    Text("(\(count))")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(FanChatTheme.neonBlue)
                }

                Spacer()
            }

            VStack(spacing: 1) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(FanChatTheme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
            )
        }
    }

    // MARK: - Team Row
    private func teamRow(_ team: SportsTeam) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [team.primaryColor, team.secondaryColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .glow(team.primaryColor, radius: 4)

                Text(team.logoEmoji)
                    .font(.system(size: 20))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(team.fullName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FanChatTheme.textPrimary)
                Text(team.league.displayName)
                    .font(.system(size: 12))
                    .foregroundColor(FanChatTheme.textTertiary)
            }

            Spacer()

            Button {
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                preferences.unfollowTeam(team)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(FanChatTheme.neonPink)
                    .glow(FanChatTheme.neonPink, radius: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Empty Teams View
    private var emptyTeamsView: some View {
        HStack(spacing: 12) {
            Image(systemName: "sportscourt")
                .font(.system(size: 18))
                .foregroundColor(FanChatTheme.textTertiary)
            Text("No teams followed")
                .font(.system(size: 15))
                .foregroundColor(FanChatTheme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - Empty Blocked View
    private var emptyBlockedView: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.slash")
                .font(.system(size: 18))
                .foregroundColor(FanChatTheme.textTertiary)
            Text("No blocked users")
                .font(.system(size: 15))
                .foregroundColor(FanChatTheme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - Blocked Users Row
    private var blockedUsersRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.slash.fill")
                .font(.system(size: 18))
                .foregroundColor(FanChatTheme.neonPink)
            Text("\(preferences.blockedUserIds.count) user\(preferences.blockedUserIds.count == 1 ? "" : "s") blocked")
                .font(.system(size: 15))
                .foregroundColor(FanChatTheme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // MARK: - Info Row
    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(FanChatTheme.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(FanChatTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Profile Card
    private var profileCard: some View {
        Button {
            showingEditProfile = true
        } label: {
            VStack(spacing: 0) {
                // Hero avatar + name + bio
                VStack(spacing: 10) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(profileGradientPair.0.opacity(0.15))
                            .frame(width: 96, height: 96)
                            .blur(radius: 12)

                        if let imageData = preferences.avatarImageData,
                           let uiImage = UIImage(data: imageData) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 76, height: 76)
                                .clipShape(Circle())
                                .overlay(
                                    Circle()
                                        .stroke(
                                            LinearGradient(
                                                colors: [profileGradientPair.0, profileGradientPair.1],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            ),
                                            lineWidth: 2.5
                                        )
                                )
                        } else {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [profileGradientPair.0, profileGradientPair.1],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 76, height: 76)

                            Text(preferences.avatarEmoji)
                                .font(.system(size: 38))
                        }
                    }

                    // Username
                    Text(preferences.displayName)
                        .font(.system(size: 20, weight: .black))
                        .foregroundColor(FanChatTheme.textPrimary)

                    // Bio
                    if preferences.hasBio {
                        Text(preferences.bio)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(FanChatTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal, 24)
                    }

                    // Edit hint
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Edit Profile")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(FanChatTheme.neonCyan)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                .padding(.bottom, 16)

                // Team badges
                if !preferences.followedTeams.isEmpty {
                    Rectangle()
                        .fill(FanChatTheme.backgroundTertiary)
                        .frame(height: 1)
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(preferences.followedTeams.prefix(6)) { team in
                                HStack(spacing: 5) {
                                    ZStack {
                                        Circle()
                                            .fill(
                                                LinearGradient(
                                                    colors: [team.primaryColor, team.secondaryColor],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 24, height: 24)

                                        Text(team.logoEmoji)
                                            .font(.system(size: 12))
                                    }

                                    Text(team.shortName)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(FanChatTheme.textPrimary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule()
                                        .fill(team.primaryColor.opacity(0.12))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(team.primaryColor.opacity(0.3), lineWidth: 1)
                                )
                            }

                            if preferences.followedTeams.count > 6 {
                                Text("+\(preferences.followedTeams.count - 6)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(FanChatTheme.textTertiary)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.vertical, 12)
                }

                // Social links
                if preferences.hasSocialLinks {
                    Rectangle()
                        .fill(FanChatTheme.backgroundTertiary)
                        .frame(height: 1)
                        .padding(.horizontal, 16)

                    HStack(spacing: 8) {
                        if !preferences.socialTwitter.isEmpty {
                            socialPill(icon: "at", handle: preferences.socialTwitter, urlString: "https://x.com/\(preferences.socialTwitter)")
                        }
                        if !preferences.socialInstagram.isEmpty {
                            socialPill(icon: "camera", handle: preferences.socialInstagram, urlString: "https://instagram.com/\(preferences.socialInstagram)")
                        }
                        if !preferences.socialTikTok.isEmpty {
                            socialPill(icon: "play.rectangle", handle: preferences.socialTikTok, urlString: "https://tiktok.com/@\(preferences.socialTikTok)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(FanChatTheme.cardGradient)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sign Out Button
    private var signOutButton: some View {
        Button {
            showingSignOutAlert = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 18))
                    .foregroundColor(FanChatTheme.neonPink)
                    .glow(FanChatTheme.neonPink, radius: 4)
                Text("Sign Out")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FanChatTheme.neonPink)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    // MARK: - Reset Button
    private var resetButton: some View {
        Button {
            showingResetAlert = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 18))
                    .foregroundColor(FanChatTheme.neonRed)
                    .glow(FanChatTheme.neonRed, radius: 4)
                Text("Reset Onboarding")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FanChatTheme.neonRed)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    #if DEBUG
    // MARK: - Debug: Test Remote Vote
    //
    // Exercises `RemoteChatService` end-to-end (fetch → pick latest → vote)
    // without flipping `useRemoteChat`, so the rest of the app stays on the
    // mock and there's zero risk of a wider freeze. All output goes to the
    // console — find with the prefix `[TestRemoteVote]`.

    private var testRemoteVoteButton: some View {
        Button {
            Task { await runRemoteVoteTest() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "flask.fill")
                    .font(.system(size: 18))
                    .foregroundColor(FanChatTheme.neonCyan)
                Text("Test Remote Vote")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FanChatTheme.neonCyan)
                Spacer()
                Text("Bulls")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func runRemoteVoteTest() async {
        print("🧪 [TestRemoteVote] STARTING")

        // Step 1 — resolve the Bulls' stable team id.
        guard let bulls = TeamDatabase.nbaTeams.first(where: { $0.shortName == "CHI" }) else {
            print("❌ [TestRemoteVote] Step 1 FAILED: Chicago Bulls not found in TeamDatabase")
            return
        }
        print("🧪 [TestRemoteVote] Step 1: Bulls team id = \(bulls.id.uuidString)")

        // Step 2 — fetch posts for the Bulls.
        print("🧪 [TestRemoteVote] Step 2: fetchPostsForTeam…")
        let posts: [Post]
        do {
            posts = try await RemoteChatService.shared.fetchPostsForTeam(bulls.id, sortBy: .new)
            print("✅ [TestRemoteVote] Step 2: fetched \(posts.count) post(s)")
        } catch {
            print("❌ [TestRemoteVote] Step 2 FAILED: \(error)")
            return
        }

        // Step 3 — pick the most recent (fetchPostsForTeam orders DESC by created_at,
        // so the head of the array is freshest).
        guard let mostRecent = posts.first else {
            print("⚠️ [TestRemoteVote] Step 3: no posts found for Bulls — nothing to vote on")
            return
        }
        let preview = mostRecent.content.prefix(60)
        print("🧪 [TestRemoteVote] Step 3: most recent post = \(mostRecent.id.uuidString)")
        print("    content: \"\(preview)\"")
        print("    current upvotes: \(mostRecent.upvotes)  downvotes: \(mostRecent.downvotes)")

        // Step 4 — toggle. The vote cache was preloaded by Step 2's fetch,
        // so `getUserVote(for:)` reflects the user's current state for this
        // post. If they already upvoted → removeVote (the "off" half of a
        // toggle); otherwise (no vote, or a downvote) → upvote.
        let priorVote = RemoteChatService.shared.getUserVote(for: mostRecent.id)
        let priorDescription: String = {
            switch priorVote {
            case .upvote:   return "upvote"
            case .downvote: return "downvote"
            case nil:       return "none"
            }
        }()
        print("🧪 [TestRemoteVote] Step 4: prior vote = \(priorDescription)")

        do {
            let updated: Post
            if priorVote == .upvote {
                print("🧪 [TestRemoteVote] Step 4: path = REMOVE (prior was upvote)")
                updated = try await RemoteChatService.shared.removeVote(from: mostRecent.id)
                print("✅ [TestRemoteVote] Step 4: removeVote succeeded")
            } else {
                print("🧪 [TestRemoteVote] Step 4: path = UPVOTE (prior was \(priorDescription))")
                updated = try await RemoteChatService.shared.vote(on: mostRecent.id, type: .upvote)
                print("✅ [TestRemoteVote] Step 4: vote succeeded")
            }
            print("    new upvotes: \(updated.upvotes)  downvotes: \(updated.downvotes)")
        } catch {
            print("❌ [TestRemoteVote] Step 4 FAILED: \(error)")
            return
        }

        print("🧪 [TestRemoteVote] DONE")
    }

    // MARK: - Debug: Reset Local User
    //
    // Wipes the device's local user identity (userId + profile) so the
    // same physical device can simulate a different user — used to test
    // chat across simulator + iPhone with one Apple ID. Does NOT touch
    // Supabase data; the new identity creates fresh server rows on first
    // post via `ensureCurrentUserExists`. Followed teams, onboarding,
    // and block list are preserved (they're content prefs, not identity).
    //
    // Calls `exit(0)` after clearing because the chat-service singletons
    // (MockChatService / RemoteChatService) captured the old `userId` at
    // init and won't pick up the new id without a fresh process launch.
    // `exit(0)` is App-Store-prohibited but safe for DEBUG builds; this
    // entire section is `#if DEBUG`-gated so it never ships.

    private var resetLocalUserButton: some View {
        Button {
            performResetLocalUser()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.xmark")
                    .font(.system(size: 18))
                    .foregroundColor(FanChatTheme.neonRed)
                Text("Reset Local User")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FanChatTheme.neonRed)
                Spacer()
                Text("Exits app")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(FanChatTheme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private func performResetLocalUser() {
        print("🧹 [ResetLocalUser] starting — old userId=\(UserPreferences.shared.userId.uuidString)")
        UserPreferences.shared.resetLocalIdentity()
        print("🧹 [ResetLocalUser] done — new userId=\(UserPreferences.shared.userId.uuidString)")
        print("🧹 [ResetLocalUser] exiting process so chat-service singletons re-init on next launch …")

        // Tiny delay so the print buffer flushes before the process dies.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            exit(0)
        }
    }
    #endif

    // MARK: - Social Pill
    private func socialPill(icon: String, handle: String, urlString: String) -> some View {
        Group {
            if let url = URL(string: urlString) {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                        Text("@\(handle)")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(FanChatTheme.neonCyan)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(FanChatTheme.neonCyan.opacity(0.1))
                    )
                    .overlay(
                        Capsule()
                            .stroke(FanChatTheme.neonCyan.opacity(0.3), lineWidth: 1)
                    )
                }
            }
        }
    }
}

// MARK: - Edit Profile Sheet
struct EditProfileSheet: View {
    @ObservedObject var preferences: UserPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var selectedEmoji = ""
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var avatarImageData: Data? = nil
    @State private var bio = ""
    @State private var socialTwitter = ""
    @State private var socialInstagram = ""
    @State private var socialTikTok = ""
    @State private var avatarColorHex = "#00D9FF"
    @FocusState private var isUsernameFocused: Bool
    @FocusState private var isBioFocused: Bool

    private var selectedAvatarColor: Color {
        Color(hex: avatarColorHex)
    }

    private var selectedGradientPair: (Color, Color) {
        Self.gradientOptions.first(where: { $0.hex == avatarColorHex })
            .map { ($0.from, $0.to) } ?? (Color(hex: avatarColorHex), Color(hex: avatarColorHex).opacity(0.5))
    }

    struct GradientOption: Identifiable {
        let hex: String
        let from: Color
        let to: Color
        var id: String { hex }
    }

    static let gradientOptions: [GradientOption] = [
        // Row 1: Cool tones
        GradientOption(hex: "#00D9FF", from: Color(hex: "#00D9FF"), to: Color(hex: "#0080FF")),
        GradientOption(hex: "#0080FF", from: Color(hex: "#0080FF"), to: Color(hex: "#004AFF")),
        GradientOption(hex: "#4A00E0", from: Color(hex: "#4A00E0"), to: Color(hex: "#8E2DE2")),
        GradientOption(hex: "#B537F2", from: Color(hex: "#B537F2"), to: Color(hex: "#7B2FBE")),
        GradientOption(hex: "#6A11CB", from: Color(hex: "#6A11CB"), to: Color(hex: "#2575FC")),
        GradientOption(hex: "#00C9FF", from: Color(hex: "#00C9FF"), to: Color(hex: "#92FE9D")),
        // Row 2: Warm tones
        GradientOption(hex: "#FF6B35", from: Color(hex: "#FF6B35"), to: Color(hex: "#F7971E")),
        GradientOption(hex: "#FF006E", from: Color(hex: "#FF006E"), to: Color(hex: "#FF4B2B")),
        GradientOption(hex: "#FF3131", from: Color(hex: "#FF3131"), to: Color(hex: "#FF8008")),
        GradientOption(hex: "#F7971E", from: Color(hex: "#F7971E"), to: Color(hex: "#FFD200")),
        GradientOption(hex: "#FFE500", from: Color(hex: "#FFE500"), to: Color(hex: "#FF9A00")),
        GradientOption(hex: "#FC466B", from: Color(hex: "#FC466B"), to: Color(hex: "#3F5EFB")),
        // Row 3: Nature / Earth
        GradientOption(hex: "#00FF41", from: Color(hex: "#00FF41"), to: Color(hex: "#00B4DB")),
        GradientOption(hex: "#11998E", from: Color(hex: "#11998E"), to: Color(hex: "#38EF7D")),
        GradientOption(hex: "#56AB2F", from: Color(hex: "#56AB2F"), to: Color(hex: "#A8E063")),
        GradientOption(hex: "#0F9B0F", from: Color(hex: "#0F9B0F"), to: Color(hex: "#000000")),
        GradientOption(hex: "#3A1C71", from: Color(hex: "#3A1C71"), to: Color(hex: "#FFAF7B")),
        GradientOption(hex: "#ED4264", from: Color(hex: "#ED4264"), to: Color(hex: "#FFEDBC")),
        // Row 4: Premium / Dark
        GradientOption(hex: "#C0C0C0", from: Color(hex: "#C0C0C0"), to: Color(hex: "#555555")),
        GradientOption(hex: "#D4AF37", from: Color(hex: "#D4AF37"), to: Color(hex: "#8B6914")),
        GradientOption(hex: "#E8CBC0", from: Color(hex: "#E8CBC0"), to: Color(hex: "#636FA4")),
        GradientOption(hex: "#DA22FF", from: Color(hex: "#DA22FF"), to: Color(hex: "#9733EE")),
        GradientOption(hex: "#F953C6", from: Color(hex: "#F953C6"), to: Color(hex: "#B91D73")),
        GradientOption(hex: "#FFFFFF", from: Color(hex: "#FFFFFF"), to: Color(hex: "#76B852")),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                FanChatTheme.backgroundPrimary
                    .ignoresSafeArea()

                NoiseBackground()
                    .opacity(0.3)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 32) {
                        // Avatar preview with camera button
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(selectedGradientPair.0.opacity(0.3))
                                    .frame(width: 140, height: 140)
                                    .blur(radius: 20)

                                if let imageData = avatarImageData,
                                   let uiImage = UIImage(data: imageData) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 110, height: 110)
                                        .clipShape(Circle())
                                        .overlay(
                                            Circle()
                                                .stroke(
                                                    LinearGradient(
                                                        colors: [selectedGradientPair.0, selectedGradientPair.1],
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    ),
                                                    lineWidth: 3
                                                )
                                        )
                                } else {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [selectedGradientPair.0, selectedGradientPair.1],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .frame(width: 110, height: 110)

                                    Text(selectedEmoji.isEmpty ? "?" : selectedEmoji)
                                        .font(.system(size: 50))
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                PhotosPicker(
                                    selection: $selectedPhotoItem,
                                    matching: .images,
                                    photoLibrary: .shared()
                                ) {
                                    ZStack {
                                        Circle()
                                            .fill(Color(white: 0.35))
                                            .frame(width: 40, height: 40)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color(white: 0.55), lineWidth: 1.5)
                                            )

                                        Image(systemName: "camera.fill")
                                            .font(.system(size: 17, weight: .semibold))
                                            .foregroundColor(.white)
                                    }
                                }
                                .offset(x: 4, y: 4)
                            }

                            if avatarImageData != nil {
                                Button {
                                    withAnimation(AnimationConfig.snappy) {
                                        avatarImageData = nil
                                        selectedPhotoItem = nil
                                    }
                                    let generator = UIImpactFeedbackGenerator(style: .light)
                                    generator.impactOccurred()
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                        Text("Remove Photo")
                                            .font(.system(size: 13, weight: .medium))
                                    }
                                    .foregroundColor(FanChatTheme.neonPink)
                                }
                            }
                        }
                        .padding(.top, 20)

                        // Username input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("USERNAME")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(2)

                            HStack {
                                TextField("Enter username", text: $username)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(FanChatTheme.textPrimary)
                                    .focused($isUsernameFocused)
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                                    .onChange(of: username) { _, newValue in
                                        if newValue.count > UserPreferences.maxUsernameLength {
                                            username = String(newValue.prefix(UserPreferences.maxUsernameLength))
                                        }
                                    }

                                Text("\(username.count)/\(UserPreferences.maxUsernameLength)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(username.count >= UserPreferences.maxUsernameLength ? FanChatTheme.neonOrange : FanChatTheme.textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(FanChatTheme.backgroundSecondary)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(isUsernameFocused ? FanChatTheme.neonCyan.opacity(0.5) : FanChatTheme.backgroundTertiary, lineWidth: 1)
                            )

                            if !username.isEmpty && !isValidUsername {
                                Text("Username must be 2-20 characters")
                                    .font(.system(size: 12))
                                    .foregroundColor(FanChatTheme.neonOrange)
                            }
                        }
                        .padding(.horizontal, 24)

                        // Bio input
                        VStack(alignment: .leading, spacing: 8) {
                            Text("BIO")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(2)

                            VStack(alignment: .trailing, spacing: 4) {
                                TextField("Tell fans about yourself...", text: $bio, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(FanChatTheme.textPrimary)
                                    .focused($isBioFocused)
                                    .lineLimit(3...5)
                                    .onChange(of: bio) { _, newValue in
                                        if newValue.count > UserPreferences.maxBioLength {
                                            bio = String(newValue.prefix(UserPreferences.maxBioLength))
                                        }
                                    }

                                Text("\(bio.count)/\(UserPreferences.maxBioLength)")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundColor(bio.count >= UserPreferences.maxBioLength ? FanChatTheme.neonOrange : FanChatTheme.textTertiary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(FanChatTheme.backgroundSecondary)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(isBioFocused ? FanChatTheme.neonCyan.opacity(0.5) : FanChatTheme.backgroundTertiary, lineWidth: 1)
                            )
                        }
                        .padding(.horizontal, 24)

                        // Favorite teams display
                        if !preferences.followedTeams.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("FAVORITE TEAMS")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundColor(FanChatTheme.textTertiary)
                                    .tracking(2)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        ForEach(preferences.followedTeams) { team in
                                            HStack(spacing: 6) {
                                                ZStack {
                                                    Circle()
                                                        .fill(
                                                            LinearGradient(
                                                                colors: [team.primaryColor, team.secondaryColor],
                                                                startPoint: .topLeading,
                                                                endPoint: .bottomTrailing
                                                            )
                                                        )
                                                        .frame(width: 28, height: 28)

                                                    Text(team.logoEmoji)
                                                        .font(.system(size: 14))
                                                }

                                                Text(team.shortName)
                                                    .font(.system(size: 12, weight: .bold))
                                                    .foregroundColor(FanChatTheme.textPrimary)
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                Capsule()
                                                    .fill(team.primaryColor.opacity(0.15))
                                            )
                                            .overlay(
                                                Capsule()
                                                    .stroke(team.primaryColor.opacity(0.4), lineWidth: 1)
                                            )
                                        }
                                    }
                                }

                                Text("Manage teams in Settings")
                                    .font(.system(size: 11))
                                    .foregroundColor(FanChatTheme.textTertiary)
                            }
                            .padding(.horizontal, 24)
                        }

                        // Social links
                        VStack(alignment: .leading, spacing: 12) {
                            Text("SOCIAL LINKS")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(2)

                            socialHandleField(icon: "at", placeholder: "X / Twitter handle", text: $socialTwitter, accentColor: FanChatTheme.textSecondary)
                            socialHandleField(icon: "camera", placeholder: "Instagram handle", text: $socialInstagram, accentColor: FanChatTheme.neonPink)
                            socialHandleField(icon: "play.rectangle", placeholder: "TikTok handle", text: $socialTikTok, accentColor: FanChatTheme.neonCyan)
                        }
                        .padding(.horizontal, 24)

                        // Emoji selector
                        VStack(alignment: .leading, spacing: 12) {
                            Text("CHOOSE YOUR AVATAR")
                                .font(.system(size: 11, weight: .black))
                                .foregroundColor(FanChatTheme.textTertiary)
                                .tracking(2)
                                .padding(.horizontal, 16)

                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                                ForEach(AvatarEmojis.all, id: \.self) { emoji in
                                    Button {
                                        withAnimation(AnimationConfig.snappy) {
                                            selectedEmoji = emoji
                                            avatarImageData = nil
                                            selectedPhotoItem = nil
                                        }
                                        let generator = UIImpactFeedbackGenerator(style: .light)
                                        generator.impactOccurred()
                                    } label: {
                                        ZStack {
                                            Circle()
                                                .fill(selectedEmoji == emoji && avatarImageData == nil ?
                                                      FanChatTheme.neonCyan.opacity(0.2) :
                                                      FanChatTheme.backgroundSecondary)
                                                .frame(width: 52, height: 52)

                                            Text(emoji)
                                                .font(.system(size: 26))
                                        }
                                        .overlay(
                                            Circle()
                                                .stroke(selectedEmoji == emoji && avatarImageData == nil ? FanChatTheme.neonCyan : Color.clear, lineWidth: 2)
                                        )
                                        .glow(FanChatTheme.neonCyan, radius: 6, isActive: selectedEmoji == emoji && avatarImageData == nil)
                                        .scaleEffect(selectedEmoji == emoji && avatarImageData == nil ? 1.1 : 1.0)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)
                        }
                        .padding(.horizontal, 16)

                        // Gradient color picker — only for emoji avatars
                        if avatarImageData == nil {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("AVATAR COLOR")
                                    .font(.system(size: 11, weight: .black))
                                    .foregroundColor(FanChatTheme.textTertiary)
                                    .tracking(2)
                                    .padding(.horizontal, 16)

                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 6), spacing: 12) {
                                    ForEach(Self.gradientOptions) { option in
                                        Circle()
                                            .fill(
                                                LinearGradient(
                                                    colors: [option.from, option.to],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.white, lineWidth: avatarColorHex == option.hex ? 2.5 : 0)
                                            )
                                            .scaleEffect(avatarColorHex == option.hex ? 1.1 : 1.0)
                                            .onTapGesture {
                                                withAnimation(AnimationConfig.snappy) {
                                                    avatarColorHex = option.hex
                                                }
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            }
                                    }
                                }
                                .padding(.horizontal, 8)
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(FanChatTheme.backgroundPrimary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(FanChatTheme.textSecondary)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        preferences.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
                        preferences.avatarEmoji = selectedEmoji
                        preferences.avatarImageData = avatarImageData
                        preferences.avatarColorHex = avatarColorHex
                        preferences.bio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
                        preferences.socialTwitter = socialTwitter.trimmingCharacters(in: .whitespacesAndNewlines)
                        preferences.socialInstagram = socialInstagram.trimmingCharacters(in: .whitespacesAndNewlines)
                        preferences.socialTikTok = socialTikTok.trimmingCharacters(in: .whitespacesAndNewlines)
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        dismiss()
                    }
                    .foregroundColor(canSave ? FanChatTheme.textSecondary : FanChatTheme.textTertiary)
                    .disabled(!canSave)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            username = preferences.username
            selectedEmoji = preferences.avatarEmoji
            avatarImageData = preferences.avatarImageData
            avatarColorHex = preferences.avatarColorHex
            bio = preferences.bio
            socialTwitter = preferences.socialTwitter
            socialInstagram = preferences.socialInstagram
            socialTikTok = preferences.socialTikTok
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data),
                   let processed = uiImage.croppedAndResized(to: 200),
                   let jpegData = processed.jpegDataCompressed(quality: 0.7) {
                    await MainActor.run {
                        avatarImageData = jpegData
                    }
                }
            }
        }
    }

    private var isValidUsername: Bool {
        preferences.isValidUsername(username)
    }

    private var canSave: Bool {
        isValidUsername && (!selectedEmoji.isEmpty || avatarImageData != nil)
    }

    private func socialHandleField(icon: String, placeholder: String, text: Binding<String>, accentColor: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(accentColor)
                .frame(width: 24)

            Text("@")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(FanChatTheme.textTertiary)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(FanChatTheme.textPrimary)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .onChange(of: text.wrappedValue) { _, newValue in
                    if newValue.hasPrefix("@") {
                        text.wrappedValue = String(newValue.dropFirst())
                    }
                    if text.wrappedValue.count > UserPreferences.maxSocialHandleLength {
                        text.wrappedValue = String(text.wrappedValue.prefix(UserPreferences.maxSocialHandleLength))
                    }
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(FanChatTheme.backgroundTertiary, lineWidth: 1)
        )
    }
}

#Preview {
    MainTabView(preferences: UserPreferences.shared)
}
