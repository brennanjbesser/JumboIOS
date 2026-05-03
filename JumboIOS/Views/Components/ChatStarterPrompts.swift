import SwiftUI

// MARK: - Chat Starter Prompts
//
// Active starter state for empty chat feeds. Renders three lightweight
// system-prompt cards in place of the old "No posts yet" message so the room
// always feels alive and gives the user something to react to.

struct ChatStarterPrompts: View {
    let prompts: [String]

    static let defaultPrompts: [String] = [
        "Game thread is warming up 🔥",
        "Who are you riding with tonight?",
        "Drop your first take below 👇"
    ]

    init(prompts: [String] = ChatStarterPrompts.defaultPrompts) {
        self.prompts = prompts
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                StarterPromptCard(text: prompt)
                    .slideIn(delay: Double(index) * 0.06)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

// MARK: - Single starter card

struct StarterPromptCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // System badge — JUMBO mark, clearly distinct from real user posts.
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [FanChatTheme.neonOrange, FanChatTheme.neonPink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 32, height: 32)

                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("JUMBO")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundColor(FanChatTheme.textPrimary)

                    Text("STARTER")
                        .font(.system(size: 9, weight: .black))
                        .tracking(1.2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(FanChatTheme.neonOrange.opacity(0.85))
                        )
                }

                Text(text)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FanChatTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
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
