import SwiftUI

struct GameBanner: View {
    let game: Game
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                // Status indicator
                HStack(spacing: 4) {
                    if game.status.isActive {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                            .modifier(PulseAnimation())
                    }

                    Text(statusText)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(statusColor)
                        .textCase(.uppercase)
                }

                // Teams and Score
                HStack(spacing: 12) {
                    // Away team
                    VStack(spacing: 4) {
                        Text(game.awayTeam.shortName)
                            .font(.system(size: 14, weight: .bold))
                        Text("\(game.awayScore)")
                            .font(.system(size: 20, weight: .heavy))
                    }
                    .frame(width: 50)

                    // Divider / Time
                    VStack(spacing: 2) {
                        if game.status.isActive {
                            Text(game.currentPeriod ?? "")
                                .font(.system(size: 10, weight: .medium))
                            Text(game.timeRemaining ?? "")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        } else if game.status == .scheduled {
                            Text(formattedTime)
                                .font(.system(size: 12, weight: .medium))
                        } else {
                            Text("FINAL")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .foregroundColor(.secondary)

                    // Home team
                    VStack(spacing: 4) {
                        Text(game.homeTeam.shortName)
                            .font(.system(size: 14, weight: .bold))
                        Text("\(game.homeScore)")
                            .font(.system(size: 20, weight: .heavy))
                    }
                    .frame(width: 50)
                }

                // Post count indicator
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 10))
                    Text("Live Chat")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var statusText: String {
        switch game.status {
        case .live:
            return "LIVE"
        case .halftime:
            return "HALFTIME"
        case .scheduled:
            return "Upcoming"
        case .final_:
            return "Final"
        }
    }

    private var statusColor: Color {
        switch game.status {
        case .live, .halftime:
            return .red
        case .scheduled:
            return .secondary
        case .final_:
            return .primary
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: game.startTime)
    }
}

// MARK: - Pulse Animation
struct PulseAnimation: ViewModifier {
    @State private var isAnimating = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isAnimating ? 1.2 : 1.0)
            .opacity(isAnimating ? 0.6 : 1.0)
            .animation(
                .easeInOut(duration: 0.8)
                .repeatForever(autoreverses: true),
                value: isAnimating
            )
            .onAppear {
                isAnimating = true
            }
    }
}

// MARK: - Horizontal Game Scroller
struct GameScroller: View {
    let games: [Game]
    @Binding var selectedGameId: UUID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                // All games option
                AllGamesButton(
                    isSelected: selectedGameId == nil,
                    onTap: { selectedGameId = nil }
                )

                ForEach(games) { game in
                    GameBanner(
                        game: game,
                        isSelected: selectedGameId == game.id,
                        onTap: { selectedGameId = game.id }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

struct AllGamesButton: View {
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                Image(systemName: "sportscourt.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.accentColor)

                Text("All Games")
                    .font(.system(size: 13, weight: .semibold))

                Text("View all posts")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .frame(width: 100)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack {
        GameBanner(
            game: Game(
                sportId: UUID(),
                homeTeam: Team(name: "Kansas City Chiefs", shortName: "KC", sportId: UUID(), primaryColor: "#E31837", secondaryColor: "#FFB81C"),
                awayTeam: Team(name: "Baltimore Ravens", shortName: "BAL", sportId: UUID(), primaryColor: "#241773", secondaryColor: "#9E7C0C"),
                homeScore: 21,
                awayScore: 17,
                startTime: Date(),
                status: .live,
                currentPeriod: "3rd Quarter",
                timeRemaining: "8:42"
            ),
            isSelected: true,
            onTap: {}
        )

        GameBanner(
            game: Game(
                sportId: UUID(),
                homeTeam: Team(name: "Lakers", shortName: "LAL", sportId: UUID(), primaryColor: "#552583", secondaryColor: "#FDB927"),
                awayTeam: Team(name: "Celtics", shortName: "BOS", sportId: UUID(), primaryColor: "#007A33", secondaryColor: "#BA9653"),
                startTime: Date().addingTimeInterval(7200),
                status: .scheduled
            ),
            isSelected: false,
            onTap: {}
        )
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
