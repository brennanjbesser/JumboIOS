import SwiftUI

// MARK: - Quick Post Chips Rail
//
// Horizontal scroll of compact reaction chips, intended to live inside the
// New Post sheet (above the text input / below the "Posting to" header).
// Tapping a chip populates the composer's text field — it does NOT submit.
// The user can then edit and tap Post manually.

struct QuickPostChipsRail: View {
    /// Called with the chip's text when the user taps it. Caller should set
    /// the composer's content state to this value.
    let onPick: (String) -> Void

    /// Default rail content. Override via init when a screen wants a
    /// different set without changing call-site shape.
    static let defaultChips: [String] = [
        "LET'S GO 🔥",
        "Refs??",
        "What a play 😳",
        "No way 💀",
        "Who wins?"
    ]

    private let chips: [String]

    init(chips: [String] = QuickPostChipsRail.defaultChips, onPick: @escaping (String) -> Void) {
        self.chips = chips
        self.onPick = onPick
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    QuickPostChip(text: chip) {
                        let g = UIImpactFeedbackGenerator(style: .light)
                        g.impactOccurred()
                        onPick(chip)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Single chip

private struct QuickPostChip: View {
    let text: String
    let action: () -> Void

    @State private var pressed: Bool = false

    var body: some View {
        Button {
            // Quick scale-down feedback, then populate the field.
            withAnimation(.easeOut(duration: 0.08)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                    pressed = false
                }
                action()
            }
        } label: {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(FanChatTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(FanChatTheme.backgroundTertiary)
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .scaleEffect(pressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
    }
}
