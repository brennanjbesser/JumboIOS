import SwiftUI

struct RootView: View {
    @StateObject private var preferences = UserPreferences.shared
    @StateObject private var authService = AuthenticationService.shared
    @State private var onboardingStep: OnboardingStep = .signIn
    @State private var showLaunchScreen = true

    enum OnboardingStep {
        case signIn
        case welcome
        case profileSetup
        case teamSelection
        case complete
    }

    // TEMPORARY: Set to true to bypass login flow for testing
    private let bypassLogin = true

    var body: some View {
        ZStack {
            Group {
                if bypassLogin {
                    // TEMPORARY: Go directly to main app for testing
                    MainTabView(preferences: preferences)
                } else if preferences.hasCompletedOnboarding && authService.isSignedIn {
                    MainTabView(preferences: preferences)
                } else {
                    onboardingFlow
                }
            }
            .animation(.easeInOut(duration: 0.3), value: preferences.hasCompletedOnboarding)
            .animation(.easeInOut(duration: 0.3), value: onboardingStep)
            .animation(.easeInOut(duration: 0.3), value: authService.isSignedIn)

            // Launch Screen overlay
            if showLaunchScreen {
                LaunchScreenView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            // Skip auth checks if bypassing login
            if bypassLogin {
                // Dismiss launch screen after a short delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        showLaunchScreen = false
                    }
                }
                return
            }

            // Check if user is already signed in and completed onboarding
            if authService.isSignedIn && !preferences.hasCompletedOnboarding {
                onboardingStep = .welcome
            } else if !authService.isSignedIn {
                onboardingStep = .signIn
            }

            // Dismiss launch screen after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.4)) {
                    showLaunchScreen = false
                }
            }
        }
        .onChange(of: authService.authState) { _, newState in
            // Skip if bypassing login
            if bypassLogin { return }

            if case .signedIn = newState {
                // User just signed in, move to welcome/onboarding
                if !preferences.hasCompletedOnboarding {
                    withAnimation {
                        onboardingStep = .welcome
                    }
                }
            } else if case .signedOut = newState {
                // User signed out, go back to sign in
                withAnimation {
                    onboardingStep = .signIn
                }
            }
        }
    }

    @ViewBuilder
    private var onboardingFlow: some View {
        switch onboardingStep {
        case .signIn:
            SignInView(authService: authService) {
                withAnimation {
                    onboardingStep = .welcome
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            ))

        case .welcome:
            WelcomeView {
                withAnimation {
                    onboardingStep = .profileSetup
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            ))

        case .profileSetup:
            ProfileSetupView(preferences: preferences) {
                withAnimation {
                    onboardingStep = .teamSelection
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            ))

        case .teamSelection:
            TeamSelectionView(preferences: preferences) {
                withAnimation {
                    onboardingStep = .complete
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: .trailing),
                removal: .move(edge: .leading)
            ))

        case .complete:
            // This state triggers the main app
            Color.clear
                .onAppear {
                    // Small delay to ensure smooth transition
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        preferences.completeOnboarding()
                    }
                }
        }
    }
}

#Preview {
    RootView()
}
