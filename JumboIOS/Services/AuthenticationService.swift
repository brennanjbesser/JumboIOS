import Foundation
import SwiftUI
import Combine

// MARK: - Authentication State
enum AuthenticationState: Equatable {
    case unknown
    case signedOut
    case signedIn(userId: String)
}

// MARK: - User Credentials
struct UserCredentials: Codable {
    let userId: String
    let email: String?
    let displayName: String?
}

// MARK: - Authentication Service
@MainActor
class AuthenticationService: ObservableObject {
    static let shared = AuthenticationService()

    @Published var authState: AuthenticationState = .unknown
    @Published var currentUser: UserCredentials?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let userIdKey = "userID"

    var isSignedIn: Bool {
        if case .signedIn = authState {
            return true
        }
        return false
    }

    private init() {
        checkExistingCredentials()
    }

    // MARK: - Check Existing Credentials
    func checkExistingCredentials() {
        guard let userId = UserDefaults.standard.string(forKey: userIdKey) else {
            authState = .signedOut
            return
        }

        authState = .signedIn(userId: userId)
        currentUser = UserCredentials(userId: userId, email: nil, displayName: nil)
    }

    // MARK: - Sign In (placeholder for future implementation)
    func signIn() {
        isLoading = true

        // Generate a temporary user ID for testing
        let userId = UUID().uuidString
        UserDefaults.standard.set(userId, forKey: userIdKey)

        currentUser = UserCredentials(userId: userId, email: nil, displayName: nil)
        authState = .signedIn(userId: userId)
        isLoading = false

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    // MARK: - Sign Out
    func signOut() {
        // Clear stored credentials
        UserDefaults.standard.removeObject(forKey: userIdKey)

        // Update state
        currentUser = nil
        authState = .signedOut

        // Reset user preferences
        UserPreferences.shared.resetOnboarding()

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }
}
