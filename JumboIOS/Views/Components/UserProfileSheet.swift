import SwiftUI

struct UserProfileSheet: View {
    let authorId: UUID
    @ObservedObject private var preferences = UserPreferences.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingBlockAlert = false

    // MARK: - Derived from authorId (deterministic)

    private var anonymousName: String {
        let colors = ["Red", "Blue", "Green", "Gold", "Silver", "Purple", "Orange", "Teal", "Crimson", "Navy"]
        let animals = ["Fan", "Hawk", "Tiger", "Bear", "Wolf", "Eagle", "Lion", "Shark", "Bull", "Panther"]
        let hash = authorId.hashValue
        let colorIndex = abs(hash) % colors.count
        let animalIndex = abs(hash / colors.count) % animals.count
        return "\(colors[colorIndex]) \(animals[animalIndex])"
    }

    private var avatarEmoji: String {
        let hash = abs(authorId.hashValue)
        return AvatarEmojis.all[hash % AvatarEmojis.all.count]
    }

    private var gradientColors: [Color] {
        let allColors: [Color] = [
            FanChatTheme.neonCyan, FanChatTheme.neonPurple,
            FanChatTheme.neonOrange, FanChatTheme.neonPink,
            FanChatTheme.neonGreen, FanChatTheme.neonBlue
        ]
        let hash = abs(authorId.hashValue)
        let i1 = hash % allColors.count
        let i2 = (hash / allColors.count) % allColors.count
        return [allColors[i1], allColors[i2 == i1 ? (i2 + 1) % allColors.count : i2]]
    }

    private var isOwnProfile: Bool {
        authorId == preferences.userId
    }

    private var isBlocked: Bool {
        preferences.isBlocked(authorId)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            NoiseBackground()
                .opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Hero avatar + name
                VStack(spacing: 12) {
                    // Avatar
                    ZStack {
                        Circle()
                            .fill(gradientColors.first!.opacity(0.15))
                            .frame(width: 100, height: 100)
                            .blur(radius: 14)

                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: gradientColors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 80, height: 80)
                            .glow(gradientColors.first!, radius: 10)

                        Text(avatarEmoji)
                            .font(.system(size: 40))
                    }

                    // Name
                    Text(anonymousName)
                        .font(.system(size: 22, weight: .black))
                        .foregroundColor(FanChatTheme.textPrimary)

                    // Subtitle
                    Text(isOwnProfile ? "This is you" : "Anonymous Fan")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(FanChatTheme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
                .padding(.bottom, 24)

                // Actions
                if !isOwnProfile {
                    Rectangle()
                        .fill(FanChatTheme.backgroundTertiary)
                        .frame(height: 1)
                        .padding(.horizontal, 24)

                    VStack(spacing: 12) {
                        // Block / Unblock
                        Button {
                            if isBlocked {
                                preferences.unblockUser(authorId)
                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                generator.impactOccurred()
                            } else {
                                showingBlockAlert = true
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isBlocked ? "person.crop.circle.badge.checkmark" : "person.slash.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                Text(isBlocked ? "Unblock User" : "Block User")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundColor(isBlocked ? FanChatTheme.neonGreen : FanChatTheme.neonPink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill((isBlocked ? FanChatTheme.neonGreen : FanChatTheme.neonPink).opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke((isBlocked ? FanChatTheme.neonGreen : FanChatTheme.neonPink).opacity(0.3), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                }

                Spacer()
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(FanChatTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
        .alert("Block \(anonymousName)?", isPresented: $showingBlockAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Block", role: .destructive) {
                preferences.blockUser(authorId)
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                dismiss()
            }
        } message: {
            Text("Their posts will be hidden from your feed. You can unblock them in Settings.")
        }
    }
}
