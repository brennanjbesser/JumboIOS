import Foundation
import UserNotifications

@MainActor
class NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    private init() {}

    // MARK: - Permission

    func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Schedule

    func scheduleGameNotification(
        gameId: UUID,
        homeTeam: String,
        awayTeam: String,
        league: String,
        startTime: Date
    ) {
        let interval = startTime.timeIntervalSinceNow

        // Don't schedule if the game already started
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Game Starting! \u{1F3C8}"
        content.body = "\(league): \(awayTeam) vs \(homeTeam) is starting now!"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: interval,
            repeats: false
        )

        let request = UNNotificationRequest(
            identifier: gameId.uuidString,
            content: content,
            trigger: trigger
        )

        center.add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cancel

    func cancelGameNotification(gameId: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: [gameId.uuidString]
        )
    }
}
