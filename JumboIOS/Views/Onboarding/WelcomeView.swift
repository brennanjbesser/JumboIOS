import SwiftUI

struct WelcomeView: View {
    let onContinue: () -> Void

    @State private var showContent = false
    @State private var glowIntensity: Double = 0

    var body: some View {
        ZStack {
            // Dark background with noise
            FanChatTheme.backgroundPrimary
                .ignoresSafeArea()

            NoiseBackground()
                .opacity(0.3)
                .ignoresSafeArea()

            // Animated neon background elements
            GeometryReader { geometry in
                ForEach(0..<8, id: \.self) { index in
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    neonColors[index % neonColors.count].opacity(0.15),
                                    neonColors[index % neonColors.count].opacity(0.05)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: CGFloat.random(in: 150...300))
                        .position(
                            x: positions[index].x * geometry.size.width,
                            y: positions[index].y * geometry.size.height
                        )
                        .blur(radius: 50)
                }
            }

            VStack(spacing: 0) {
                Spacer()

                // Logo/Icon with neon glow
                VStack(spacing: 28) {
                    ZStack {
                        // Outer glow
                        Circle()
                            .fill(FanChatTheme.neonCyan.opacity(0.3))
                            .frame(width: 160, height: 160)
                            .blur(radius: 30)
                            .scaleEffect(showContent ? 1 : 0.5)

                        // Main circle
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [FanChatTheme.neonCyan, FanChatTheme.neonPurple],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 120, height: 120)
                            .glow(FanChatTheme.neonCyan, radius: 20)

                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.white)
                    }
                    .scaleEffect(showContent ? 1 : 0.5)
                    .opacity(showContent ? 1 : 0)

                    // App Name with neon styling
                    VStack(spacing: 10) {
                        Text("JUMBO")
                            .font(.system(size: 52, weight: .black, design: .rounded))
                            .foregroundColor(FanChatTheme.textPrimary)
                            .glow(FanChatTheme.neonCyan, radius: 12)

                        Text("LIVE SPORTS • ANONYMOUS CHATTER")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(FanChatTheme.textSecondary)
                            .tracking(3)
                    }
                    .opacity(showContent ? 1 : 0)
                    .offset(y: showContent ? 0 : 20)
                }

                Spacer()

                // Features with neon accents
                VStack(spacing: 20) {
                    CasinoFeatureRow(
                        icon: "person.fill.questionmark",
                        iconColor: FanChatTheme.neonPurple,
                        title: "Stay Anonymous",
                        description: "Chat freely without revealing your identity",
                        delay: 0.3
                    )

                    CasinoFeatureRow(
                        icon: "bolt.fill",
                        iconColor: FanChatTheme.neonYellow,
                        title: "Real-Time Updates",
                        description: "See live reactions as games unfold",
                        delay: 0.4
                    )

                    CasinoFeatureRow(
                        icon: "heart.fill",
                        iconColor: FanChatTheme.neonPink,
                        title: "Follow Your Teams",
                        description: "Get posts from the teams you care about",
                        delay: 0.5
                    )
                }
                .padding(.horizontal, 28)
                .opacity(showContent ? 1 : 0)

                Spacer()

                // Continue Button with neon glow
                Button(action: {
                    let generator = UIImpactFeedbackGenerator(style: .heavy)
                    generator.impactOccurred()
                    onContinue()
                }) {
                    HStack(spacing: 12) {
                        Text("Get Started")
                            .font(.system(size: 18, weight: .bold))

                        Image(systemName: "arrow.right")
                            .font(.system(size: 16, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(
                        LinearGradient(
                            colors: [FanChatTheme.neonCyan, FanChatTheme.neonPurple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .cornerRadius(16)
                    .glow(FanChatTheme.neonCyan, radius: 16)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 30)

                // Terms
                Text("By continuing, you agree to our Terms and Privacy Policy")
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
            withAnimation(.easeOut(duration: 0.8)) {
                showContent = true
            }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                glowIntensity = 1
            }
        }
    }

    private let neonColors: [Color] = [
        FanChatTheme.neonOrange,
        FanChatTheme.neonPink,
        FanChatTheme.neonBlue,
        FanChatTheme.neonPurple,
        FanChatTheme.neonGreen,
        FanChatTheme.neonYellow,
        FanChatTheme.neonOrange,
        FanChatTheme.neonPink
    ]

    private let positions: [(x: CGFloat, y: CGFloat)] = [
        (0.2, 0.15),
        (0.85, 0.25),
        (0.1, 0.45),
        (0.9, 0.55),
        (0.3, 0.75),
        (0.7, 0.85),
        (0.5, 0.1),
        (0.6, 0.65)
    ]
}

// MARK: - Casino Feature Row
struct CasinoFeatureRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let delay: Double

    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 52, height: 52)

                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundColor(iconColor)
                    .glow(iconColor, radius: 6)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(FanChatTheme.textPrimary)

                Text(description)
                    .font(.system(size: 13))
                    .foregroundColor(FanChatTheme.textSecondary)
            }

            Spacer()
        }
        .opacity(isVisible ? 1 : 0)
        .offset(x: isVisible ? 0 : -20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(delay)) {
                isVisible = true
            }
        }
    }
}

#Preview {
    WelcomeView {
        print("Continue tapped")
    }
}
