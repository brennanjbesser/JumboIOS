import SwiftUI

struct CasinoComposeView: View {
    @ObservedObject var preferences: UserPreferences
    let onPost: (String, UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var selectedTeam: SportsTeam?
    @State private var isPosting = false
    @State private var charCountColor: Color = FanChatTheme.textTertiary
    @State private var isBoostEnabled = false
    @State private var boostSeconds: Double = 5
    @FocusState private var isTextFieldFocused: Bool

    private let maxCharacters = 280

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
                    // Team selector
                    teamSelector
                        .padding(16)

                    // Glowing divider
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, FanChatTheme.neonPurple.opacity(0.3), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1)

                    // Text editor
                    VStack(alignment: .leading, spacing: 12) {
                        ZStack(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("What's on your mind?")
                                    .font(.system(size: 18))
                                    .foregroundColor(FanChatTheme.textTertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                            }

                            TextEditor(text: $content)
                                .font(.system(size: 18))
                                .foregroundColor(FanChatTheme.textPrimary)
                                .frame(minHeight: 120)
                                .focused($isTextFieldFocused)
                                .scrollContentBackground(.hidden)
                                .background(Color.clear)
                        }

                        // Character count with glow
                        HStack {
                            if let team = selectedTeam {
                                HStack(spacing: 8) {
                                    Text("Posting to")
                                        .foregroundColor(FanChatTheme.textTertiary)

                                    HStack(spacing: 6) {
                                        Text(team.logoEmoji)
                                            .font(.system(size: 14))
                                        Text(team.shortName)
                                            .fontWeight(.bold)
                                            .foregroundColor(FanChatTheme.textPrimary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(team.primaryColor.opacity(0.2))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(team.primaryColor.opacity(0.5), lineWidth: 1)
                                    )
                                }
                                .font(.system(size: 13))
                            }

                            Spacer()

                            HStack(spacing: 0) {
                                Text("\(content.count)")
                                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                                    .foregroundColor(characterCountColor)
                                    .glow(characterCountColor, radius: content.count > maxCharacters - 20 ? 4 : 0)
                                Text("/\(maxCharacters)")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(FanChatTheme.textTertiary)
                            }
                        }
                    }
                    .padding(16)

                    // Boost section
                    BoostSection(isBoostEnabled: $isBoostEnabled, boostSeconds: $boostSeconds)
                        .padding(.horizontal, 16)

                    Spacer()

                    // Guidelines with neon styling
                    guidelinesView
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
            .navigationTitle("New Post")
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
                    Button("Post") {
                        post()
                    }
                    .foregroundColor(canPost ? FanChatTheme.textSecondary : FanChatTheme.textTertiary)
                    .disabled(!canPost || isPosting)
                }
            }
            .onAppear {
                isTextFieldFocused = true
                selectedTeam = preferences.followedTeams.first
            }
            .onChange(of: content.count) { _, newCount in
                withAnimation(.easeOut(duration: 0.2)) {
                    if newCount > maxCharacters {
                        charCountColor = FanChatTheme.neonRed
                    } else if newCount > maxCharacters - 20 {
                        charCountColor = FanChatTheme.neonOrange
                    } else {
                        charCountColor = FanChatTheme.textTertiary
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(FanChatTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
    }

    // MARK: - Team Selector
    private var teamSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SELECT TEAM")
                .font(.system(size: 11, weight: .black))
                .foregroundColor(FanChatTheme.textTertiary)
                .tracking(2)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(preferences.followedTeams) { team in
                        CasinoTeamSelectButton(
                            team: team,
                            isSelected: selectedTeam?.id == team.id
                        ) {
                            withAnimation(AnimationConfig.snappy) {
                                selectedTeam = team
                            }
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                        }
                    }
                }
            }
        }
    }

    private var guidelinesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(FanChatTheme.neonGreen)
                    .glow(FanChatTheme.neonGreen, radius: 4)

                Text("COMMUNITY GUIDELINES")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(FanChatTheme.textTertiary)
                    .tracking(1)
            }

            Text("Keep it fun and respectful. No hate speech, harassment, or spam. Posts are anonymous but moderated.")
                .font(.system(size: 13))
                .foregroundColor(FanChatTheme.textTertiary)
                .lineSpacing(3)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(FanChatTheme.neonGreen.opacity(0.2), lineWidth: 1)
        )
    }

    private var canPost: Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 && trimmed.count <= maxCharacters && !isPosting && selectedTeam != nil
    }

    private var characterCountColor: Color {
        if content.count > maxCharacters {
            return FanChatTheme.neonRed
        } else if content.count > maxCharacters - 20 {
            return FanChatTheme.neonOrange
        }
        return FanChatTheme.textTertiary
    }

    private func post() {
        guard canPost, let team = selectedTeam else { return }

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        isPosting = true
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        onPost(trimmedContent, team.id)
        dismiss()
    }
}

// MARK: - Post Button with proper state handling
struct PostButton: View {
    let canPost: Bool
    let isPosting: Bool
    let onPost: () -> Void

    var body: some View {
        Button(action: onPost) {
            if isPosting {
                ProgressView()
                    .tint(.white)
            } else {
                Text("Post")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(canPost ? .white : FanChatTheme.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(canPost ?
                                AnyShapeStyle(LinearGradient(
                                    colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )) :
                                AnyShapeStyle(Color.gray.opacity(0.3))
                            )
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!canPost || isPosting)
        .animation(.easeInOut(duration: 0.25), value: canPost)
    }
}

// MARK: - Casino Team Select Button
struct CasinoTeamSelectButton: View {
    let team: SportsTeam
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [team.primaryColor, team.secondaryColor],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 34, height: 34)
                        .glow(team.primaryColor, radius: 4, isActive: isSelected)

                    Text(team.logoEmoji)
                        .font(.system(size: 16))
                }

                Text(team.shortName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(isSelected ? FanChatTheme.textPrimary : FanChatTheme.textSecondary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(FanChatTheme.neonGreen)
                        .glow(FanChatTheme.neonGreen, radius: 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? team.primaryColor.opacity(0.2) : FanChatTheme.backgroundTertiary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? team.primaryColor.opacity(0.6) : Color.clear, lineWidth: 1.5)
            )
            .glow(team.primaryColor, radius: 6, isActive: isSelected)
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.95 : 1)
        .animation(AnimationConfig.snappy, value: isPressed)
    }
}

#Preview {
    CasinoComposeView(preferences: UserPreferences.shared) { content, teamId in
        print("Posted: \(content) to team: \(teamId)")
    }
}
