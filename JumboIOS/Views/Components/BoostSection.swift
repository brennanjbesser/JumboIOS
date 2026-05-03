import SwiftUI

struct BoostSection: View {
    @Binding var isBoostEnabled: Bool
    @Binding var boostSeconds: Double

    // 5s = $2, 50s = $10 (linear)
    private var boostPrice: Double {
        2.0 + (8.0 * (boostSeconds - 5.0) / 45.0)
    }

    private var formattedPrice: String {
        String(format: "$%.2f", boostPrice)
    }

    private var formattedSeconds: String {
        "\(Int(boostSeconds))s"
    }

    // Neon green from theme + darker shade for gradients
    private var neon: Color { FanChatTheme.neonGreen }
    private let neonDark = Color(red: 0.0, green: 0.7, blue: 0.2)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Toggle header
            Button {
                withAnimation(AnimationConfig.snappy) {
                    isBoostEnabled.toggle()
                }
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(neon)
                        .shadow(color: neon.opacity(isBoostEnabled ? 0.6 : 0.4), radius: isBoostEnabled ? 6 : 4)

                    Text("Boost Post")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(isBoostEnabled ? FanChatTheme.textPrimary : FanChatTheme.textSecondary)

                    Spacer()

                    ZStack {
                        Capsule()
                            .fill(isBoostEnabled ?
                                  AnyShapeStyle(LinearGradient(colors: [neon, neonDark], startPoint: .leading, endPoint: .trailing)) :
                                  AnyShapeStyle(FanChatTheme.backgroundTertiary))
                            .frame(width: 44, height: 26)
                            .shadow(color: isBoostEnabled ? neon.opacity(0.3) : .clear, radius: 6)

                        Circle()
                            .fill(Color.white)
                            .frame(width: 20, height: 20)
                            .offset(x: isBoostEnabled ? 10 : -10)
                    }
                }
            }
            .buttonStyle(.plain)

            if isBoostEnabled {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pin your post to the top of the chat")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(FanChatTheme.textSecondary)

                    // Price + time display
                    HStack {
                        // Time
                        VStack(spacing: 2) {
                            Text(formattedSeconds)
                                .font(.system(size: 24, weight: .black, design: .monospaced))
                                .foregroundColor(FanChatTheme.textPrimary)
                            Text("duration")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(FanChatTheme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)

                        // Divider
                        Rectangle()
                            .fill(FanChatTheme.backgroundTertiary)
                            .frame(width: 1, height: 36)

                        // Price
                        VStack(spacing: 2) {
                            Text(formattedPrice)
                                .font(.system(size: 24, weight: .black, design: .monospaced))
                                .foregroundColor(neon)
                                .shadow(color: neon.opacity(0.25), radius: 5)
                            Text("price")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(FanChatTheme.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    // Slider
                    VStack(spacing: 6) {
                        Slider(value: $boostSeconds, in: 5...50, step: 1)
                            .tint(
                                LinearGradient(
                                    colors: [neon, neonDark],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )

                        // Min/Max labels
                        HStack {
                            Text("5s • $2")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(FanChatTheme.textSecondary)
                            Spacer()
                            Text("50s • $10")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(FanChatTheme.textSecondary)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(FanChatTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isBoostEnabled ? neon.opacity(0.3) : FanChatTheme.backgroundTertiary, lineWidth: 1)
        )
        .shadow(color: isBoostEnabled ? neon.opacity(0.1) : .clear, radius: 10)
        .animation(AnimationConfig.snappy, value: isBoostEnabled)
    }
}
