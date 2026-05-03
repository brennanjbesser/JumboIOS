import SwiftUI

// MARK: - Jumbo Dark Theme Colors
struct FanChatTheme {
    // MARK: - Background Colors
    static let backgroundPrimary = Color(hex: "#0A0A0A")
    static let backgroundSecondary = Color(hex: "#1A1A1A")
    static let backgroundTertiary = Color(hex: "#252525")
    static let cardBackground = Color(hex: "#1E1E1E")
    static let cardBackgroundElevated = Color(hex: "#2A2A2A")

    // MARK: - Text Colors
    static let textPrimary = Color.white
    static let textSecondary = Color(hex: "#A0A0A0")
    static let textTertiary = Color(hex: "#666666")

    // MARK: - Neon Accent Colors
    static let neonGreen = Color(hex: "#00FF41")
    static let neonPink = Color(hex: "#FF006E")
    static let neonBlue = Color(hex: "#00D9FF")  // Teal/Cyan
    static let neonOrange = Color(hex: "#FF6B35")  // Hot filter orange
    static let neonPurple = Color(hex: "#B537F2")  // Top filter purple
    static let neonYellow = Color(hex: "#FFE500")
    static let neonRed = Color(hex: "#FF3131")
    static let neonCyan = Color(hex: "#00D9FF")  // FAB and new posts

    // MARK: - Filter Button Colors
    static let filterHot = Color(hex: "#FF6B35")
    static let filterNew = Color(hex: "#00D9FF")
    static let filterTop = Color(hex: "#B537F2")

    // MARK: - Functional Colors
    static let upvoteColor = neonGreen
    static let downvoteColor = neonPink
    static let liveIndicator = neonRed
    static let newPostsButton = neonCyan
    static let fabColor = neonCyan
    static let accentGradient = LinearGradient(
        colors: [neonOrange, neonPink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Card Gradient
    static let cardGradient = LinearGradient(
        colors: [
            Color(hex: "#2A2A2A"),
            Color(hex: "#1E1E1E")
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardGradientHover = LinearGradient(
        colors: [
            Color(hex: "#333333"),
            Color(hex: "#252525")
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: - Glow Colors
    static func glowColor(_ color: Color, opacity: Double = 0.6) -> Color {
        color.opacity(opacity)
    }

    // MARK: - Neon Team Color (intensified)
    static func neonTeamColor(_ color: Color) -> Color {
        // Make team colors more vibrant/neon
        color
    }
}

// MARK: - Noise Texture Background
struct NoiseBackground: View {
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                // Create noise texture
                for _ in 0..<Int(size.width * size.height * 0.01) {
                    let x = CGFloat.random(in: 0...size.width)
                    let y = CGFloat.random(in: 0...size.height)
                    let opacity = Double.random(in: 0.02...0.05)

                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                        with: .color(.white.opacity(opacity))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Gradient Overlays
struct GradientOverlay: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0),
                Color.black.opacity(0.3)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Dark Theme Modifier
struct DarkThemeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(.dark)
            .background(FanChatTheme.backgroundPrimary.ignoresSafeArea())
    }
}

extension View {
    func fanChatDarkTheme() -> some View {
        modifier(DarkThemeModifier())
    }
}

// MARK: - Glow Effect Modifier
struct GlowEffect: ViewModifier {
    let color: Color
    let radius: CGFloat
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .shadow(color: isActive ? color.opacity(0.8) : .clear, radius: radius)
            .shadow(color: isActive ? color.opacity(0.5) : .clear, radius: radius * 1.5)
            .shadow(color: isActive ? color.opacity(0.3) : .clear, radius: radius * 2)
    }
}

extension View {
    func glow(_ color: Color, radius: CGFloat = 8, isActive: Bool = true) -> some View {
        modifier(GlowEffect(color: color, radius: radius, isActive: isActive))
    }

    func neonGlow(_ color: Color, intensity: Double = 1.0) -> some View {
        self
            .shadow(color: color.opacity(0.8 * intensity), radius: 4)
            .shadow(color: color.opacity(0.5 * intensity), radius: 8)
            .shadow(color: color.opacity(0.3 * intensity), radius: 12)
    }
}
