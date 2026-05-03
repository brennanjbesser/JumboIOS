import SwiftUI

struct ProfileSetupView: View {
    @ObservedObject var preferences: UserPreferences
    let onContinue: () -> Void

    @State private var username = ""
    @State private var selectedEmoji: String = ""
    @State private var showContent = false
    @FocusState private var isUsernameFocused: Bool

    var body: some View {
        ZStack {
            // Dark background
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            NoiseBackground()
                .opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Header
                VStack(spacing: 16) {
                    Text("Create Your Profile")
                        .font(.system(size: 32, weight: .black))
                        .foregroundColor(FanChatTheme.textPrimary)

                    Text("Choose a username and avatar")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(FanChatTheme.textSecondary)
                }
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 20)

                Spacer()
                    .frame(height: 40)

                // Avatar preview
                avatarPreview
                    .opacity(showContent ? 1 : 0)
                    .scaleEffect(showContent ? 1 : 0.8)

                Spacer()
                    .frame(height: 32)

                // Username input
                usernameInput
                    .padding(.horizontal, 32)
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)

                Spacer()
                    .frame(height: 24)

                // Emoji selector
                emojiSelector
                    .padding(.horizontal, 16)
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 30)

                Spacer()

                // Continue button
                continueButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 30)

                // Skip option
                Text("Your profile stays anonymous to other users")
                    .font(.system(size: 12))
                    .foregroundColor(FanChatTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                    .opacity(showContent ? 1 : 0)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            selectedEmoji = preferences.avatarEmoji
            username = preferences.username

            withAnimation(.easeOut(duration: 0.6)) {
                showContent = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                isUsernameFocused = true
            }
        }
    }

    // MARK: - Avatar Preview
    private var avatarPreview: some View {
        ZStack {
            // Glow effect
            Circle()
                .fill(FanChatTheme.neonCyan.opacity(0.3))
                .frame(width: 140, height: 140)
                .blur(radius: 20)

            // Main circle with gradient
            Circle()
                .fill(
                    LinearGradient(
                        colors: [FanChatTheme.neonCyan, FanChatTheme.neonPurple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 110, height: 110)
                .glow(FanChatTheme.neonCyan, radius: 12)

            // Selected emoji
            Text(selectedEmoji.isEmpty ? "?" : selectedEmoji)
                .font(.system(size: 50))
        }
    }

    // MARK: - Username Input
    private var usernameInput: some View {
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
                        // Limit to max length
                        if newValue.count > UserPreferences.maxUsernameLength {
                            username = String(newValue.prefix(UserPreferences.maxUsernameLength))
                        }
                    }

                // Character count
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
            .glow(FanChatTheme.neonCyan, radius: 4, isActive: isUsernameFocused && isValidUsername)

            // Validation message
            if !username.isEmpty && !isValidUsername {
                Text("Username must be 2-20 characters")
                    .font(.system(size: 12))
                    .foregroundColor(FanChatTheme.neonOrange)
            }
        }
    }

    // MARK: - Emoji Selector
    private var emojiSelector: some View {
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
                        }
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(selectedEmoji == emoji ?
                                      FanChatTheme.neonCyan.opacity(0.2) :
                                      FanChatTheme.backgroundSecondary)
                                .frame(width: 52, height: 52)

                            Text(emoji)
                                .font(.system(size: 26))
                        }
                        .overlay(
                            Circle()
                                .stroke(selectedEmoji == emoji ? FanChatTheme.neonCyan : Color.clear, lineWidth: 2)
                        )
                        .glow(FanChatTheme.neonCyan, radius: 6, isActive: selectedEmoji == emoji)
                        .scaleEffect(selectedEmoji == emoji ? 1.1 : 1.0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Continue Button
    private var continueButton: some View {
        Button(action: {
            // Save preferences
            preferences.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            preferences.avatarEmoji = selectedEmoji

            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.impactOccurred()
            onContinue()
        }) {
            HStack(spacing: 12) {
                Text(canContinue ? "Continue" : "Enter Username")
                    .font(.system(size: 18, weight: .bold))

                if canContinue {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .bold))
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(canContinue ?
                          AnyShapeStyle(LinearGradient(colors: [FanChatTheme.neonCyan, FanChatTheme.neonPurple], startPoint: .leading, endPoint: .trailing)) :
                          AnyShapeStyle(FanChatTheme.backgroundTertiary))
            )
            .glow(FanChatTheme.neonCyan, radius: canContinue ? 16 : 0)
        }
        .disabled(!canContinue)
        .animation(.easeInOut(duration: 0.25), value: canContinue)
    }

    // MARK: - Helpers
    private var isValidUsername: Bool {
        preferences.isValidUsername(username)
    }

    private var canContinue: Bool {
        isValidUsername && !selectedEmoji.isEmpty
    }
}

#Preview {
    ProfileSetupView(preferences: UserPreferences.shared) {
        print("Continue")
    }
}
