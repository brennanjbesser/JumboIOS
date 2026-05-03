import SwiftUI

// MARK: - RoomHeaderView
//
// Reusable compact header for chat room screens (team chat,
// trending rooms, and any future room types like game rooms).
// Standardizes the icon + title + subtitle/activity + badge
// HStack so each room screen reads as the same family of UI.
//
// Visual contract (matches the trending header):
//   • 50pt circular icon, 26pt emoji glyph
//   • 18pt bold title
//   • 12pt semibold tertiary secondary line
//     (either a plain subtitle OR a small status-dot + activity
//      string)
//   • 10pt black-weight capsule badge on the trailing edge
//     (optional)
//   • 14pt HStack spacing
//
// The component is split into two pieces so callers can compose
// heavier layouts (e.g., team header with a live-game scoreboard
// banner appearing under the row):
//   • `RoomHeaderView` — the row content only. No padding, no
//     background. Render as-is or wrap in a VStack with extras.
//   • `.roomHeaderContainer(accentColor:)` — the surrounding
//     padding (16pt all-around) + standard subtle accent
//     gradient on FanChatTheme.backgroundSecondary. Apply to
//     the RoomHeaderView OR to a VStack containing it plus
//     extras so they share one outer container.

struct RoomHeaderView<Icon: View, Secondary: View>: View {
    let title: String
    let badge: RoomHeaderBadge?
    let icon: () -> Icon
    let secondaryContent: () -> Secondary

    init(
        title: String,
        badge: RoomHeaderBadge? = nil,
        @ViewBuilder icon: @escaping () -> Icon,
        @ViewBuilder secondaryContent: @escaping () -> Secondary
    ) {
        self.title = title
        self.badge = badge
        self.icon = icon
        self.secondaryContent = secondaryContent
    }

    var body: some View {
        HStack(spacing: 14) {
            icon()

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(FanChatTheme.textPrimary)

                // Free-form secondary slot. Default 12pt-semibold-
                // tertiary styling is applied via `.font` +
                // `.foregroundColor` (both inherited environment
                // values), so any plain `Text` inside picks them up
                // automatically. Callers compose whatever shape
                // they need — a single `Text(league)`, an HStack of
                // dot + text, or a richer multi-segment status line
                // like "● 842 active · NFL · Live · Q3 7:42".
                // Non-Text elements (e.g., a Circle dot) keep their
                // own explicit styling — `.foregroundColor` doesn't
                // tint shape `.fill()` calls.
                secondaryContent()
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(FanChatTheme.textTertiary)
            }

            Spacer()

            if let badge = badge {
                badge.view
            }
        }
    }
}

// MARK: - Trailing badge

/// Trailing capsule badge (e.g., "TRENDING" / "NFL"). The
/// `background` is `AnyShapeStyle` so callers can pass either a
/// solid color or a gradient — matches both the team-color
/// solid fill and trending's neon gradient. `systemImageName`
/// adds a leading SF Symbol (used by trending's flame).
struct RoomHeaderBadge {
    let text: String
    let systemImageName: String?
    let background: AnyShapeStyle

    init(
        text: String,
        systemImageName: String? = nil,
        background: some ShapeStyle
    ) {
        self.text = text
        self.systemImageName = systemImageName
        self.background = AnyShapeStyle(background)
    }

    fileprivate var view: some View {
        HStack(spacing: 3) {
            if let systemImageName = systemImageName {
                Image(systemName: systemImageName)
                    .font(.system(size: 10))
            }
            Text(text)
                .font(.system(size: 10, weight: .black))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(background)
        )
    }
}

// MARK: - Icon helper

/// Canonical 50pt circular icon + 26pt emoji glyph that callers
/// pass into `RoomHeaderView`'s `icon` closure. Provided as a
/// helper so the icon dimensions stay consistent across rooms
/// without each call site re-declaring the ZStack/frame/font.
struct RoomHeaderIcon: View {
    let fill: AnyShapeStyle
    let emoji: String

    init(fill: some ShapeStyle, emoji: String) {
        self.fill = AnyShapeStyle(fill)
        self.emoji = emoji
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fill)
                .frame(width: 50, height: 50)

            Text(emoji)
                .font(.system(size: 26))
        }
    }
}

// MARK: - Container styling

extension View {
    /// Standard padding + subtle accent-gradient background for a
    /// room header. Apply directly to a `RoomHeaderView`, OR to a
    /// VStack containing the header + extras (e.g., a live-game
    /// scoreboard banner) so they share one outer container.
    ///
    /// Visual:
    ///   • 16pt padding all-around
    ///   • full-width
    ///   • `FanChatTheme.backgroundSecondary` base
    ///   • leading-to-trailing `accentColor.opacity(0.10)` →
    ///     `.clear` overlay (subtle tint, not hero-style)
    func roomHeaderContainer(accentColor: Color) -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                FanChatTheme.backgroundSecondary
                    .overlay(
                        LinearGradient(
                            colors: [accentColor.opacity(0.10), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
    }
}
