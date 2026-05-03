import SwiftUI
import Combine

// MARK: - Models

struct MoneyRoom: Identifiable, Hashable {
    let id: UUID
    let title: String
    let topic: String
    let entryFee: Double
    let prizePool: Double
    let participants: Int
    let maxParticipants: Int
    let emoji: String
    let accentColor: Color
    let hostName: String
    let status: MoneyRoomStatus
    let createdAt: Date

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MoneyRoom, rhs: MoneyRoom) -> Bool {
        lhs.id == rhs.id
    }
}

enum MoneyRoomStatus: String {
    case open = "Open"
    case filling = "Filling Up"
    case live = "Live"
    case closed = "Closed"

    var color: Color {
        switch self {
        case .open: return FanChatTheme.neonGreen
        case .filling: return FanChatTheme.neonYellow
        case .live: return FanChatTheme.liveIndicator
        case .closed: return FanChatTheme.textTertiary
        }
    }
}

// MARK: - View Model

@MainActor
class MoneyTalksViewModel: ObservableObject {
    @Published var rooms: [MoneyRoom] = []

    init() {
        setupMockData()
    }

    private func setupMockData() {
        let now = Date()
        rooms = [
            MoneyRoom(
                id: UUID(),
                title: "NFL Sunday Showdown",
                topic: "Pick the winner of every Sunday game. Most correct picks takes the pot.",
                entryFee: 5.00,
                prizePool: 250.00,
                participants: 42,
                maxParticipants: 50,
                emoji: "🏈",
                accentColor: FanChatTheme.neonOrange,
                hostName: "RedWolf",
                status: .filling,
                createdAt: now.addingTimeInterval(-1800)
            ),
            MoneyRoom(
                id: UUID(),
                title: "Lakers vs Celtics Prediction",
                topic: "Predict the final score. Closest guess wins the prize pool.",
                entryFee: 10.00,
                prizePool: 500.00,
                participants: 38,
                maxParticipants: 50,
                emoji: "🏀",
                accentColor: FanChatTheme.neonPurple,
                hostName: "GoldEagle",
                status: .live,
                createdAt: now.addingTimeInterval(-3600)
            ),
            MoneyRoom(
                id: UUID(),
                title: "Hot Take Arena",
                topic: "Drop your hottest sports take. Community votes on the best one.",
                entryFee: 2.00,
                prizePool: 80.00,
                participants: 31,
                maxParticipants: 40,
                emoji: "🔥",
                accentColor: FanChatTheme.neonPink,
                hostName: "BlueTiger",
                status: .open,
                createdAt: now.addingTimeInterval(-900)
            ),
            MoneyRoom(
                id: UUID(),
                title: "MLB Home Run Derby Picks",
                topic: "Guess total home runs hit tonight. Price is right rules — closest without going over.",
                entryFee: 3.00,
                prizePool: 120.00,
                participants: 35,
                maxParticipants: 40,
                emoji: "⚾",
                accentColor: FanChatTheme.neonCyan,
                hostName: "SilverShark",
                status: .open,
                createdAt: now.addingTimeInterval(-600)
            ),
            MoneyRoom(
                id: UUID(),
                title: "Stanley Cup Finals Chat",
                topic: "Who lifts the Cup? Pick the series winner and MVP.",
                entryFee: 15.00,
                prizePool: 750.00,
                participants: 50,
                maxParticipants: 50,
                emoji: "🏒",
                accentColor: FanChatTheme.neonBlue,
                hostName: "CrimsonBear",
                status: .closed,
                createdAt: now.addingTimeInterval(-7200)
            ),
            MoneyRoom(
                id: UUID(),
                title: "Weekend Parlay Room",
                topic: "Build your best 3-leg parlay. Highest payout wins.",
                entryFee: 5.00,
                prizePool: 300.00,
                participants: 22,
                maxParticipants: 60,
                emoji: "💰",
                accentColor: FanChatTheme.neonGreen,
                hostName: "NavyPanther",
                status: .open,
                createdAt: now.addingTimeInterval(-450)
            ),
            MoneyRoom(
                id: UUID(),
                title: "Draft Day War Room",
                topic: "Mock draft challenge — build the best first round. Community judges.",
                entryFee: 20.00,
                prizePool: 1000.00,
                participants: 45,
                maxParticipants: 50,
                emoji: "👑",
                accentColor: FanChatTheme.neonYellow,
                hostName: "PurpleLion",
                status: .filling,
                createdAt: now.addingTimeInterval(-2400)
            ),
        ]
    }

    // MARK: - Create Room

    static let availableEmojis = ["🏈", "🏀", "⚾", "🏒", "🔥", "💰", "👑", "🎯", "💎", "⚡️", "🏆", "🎲"]

    static let accentColors: [Color] = [
        FanChatTheme.neonOrange,
        FanChatTheme.neonPurple,
        FanChatTheme.neonPink,
        FanChatTheme.neonCyan,
        FanChatTheme.neonGreen,
        FanChatTheme.neonYellow,
        FanChatTheme.neonBlue,
    ]

    func createRoom(title: String, description: String, entryFee: Double, durationMinutes: Int) {
        let preferences = UserPreferences.shared
        let emoji = Self.availableEmojis.randomElement() ?? "🔥"
        let color = Self.accentColors.randomElement() ?? FanChatTheme.neonOrange
        let maxParticipants = entryFee >= 10 ? 50 : 40
        let prizePool = entryFee * Double(maxParticipants) * 0.9 // 10% platform fee

        let room = MoneyRoom(
            id: UUID(),
            title: title,
            topic: description,
            entryFee: entryFee,
            prizePool: prizePool,
            participants: 1,
            maxParticipants: maxParticipants,
            emoji: emoji,
            accentColor: color,
            hostName: preferences.displayName,
            status: .open,
            createdAt: Date()
        )

        withAnimation(AnimationConfig.snappy) {
            rooms.insert(room, at: 0)
        }
    }

    func formattedCurrency(_ amount: Double) -> String {
        if amount >= 1000 {
            return String(format: "$%.0f", amount)
        }
        return amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "$%.0f", amount)
            : String(format: "$%.2f", amount)
    }
}
