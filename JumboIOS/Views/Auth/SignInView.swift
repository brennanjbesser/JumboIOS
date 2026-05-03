import SwiftUI

struct SignInView: View {
    @ObservedObject var authService: AuthenticationService
    let onSignIn: () -> Void

    @State private var showContent = false
    @State private var showError = false

    var body: some View {
        ZStack {
            // Pure black background to match logo
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo and branding
                VStack(spacing: 16) {
                    // App Logo Image
                    Image("JumboLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .scaleEffect(showContent ? 1 : 0.5)
                        .opacity(showContent ? 1 : 0)

                    // Subtitle
                    Text("LIVE SPORTS CHAT")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(FanChatTheme.textSecondary)
                        .tracking(4)
                        .opacity(showContent ? 1 : 0)
                        .offset(y: showContent ? 0 : 20)
                }

                Spacer()

                // Features highlight
                VStack(spacing: 16) {
                    FeatureHighlight(
                        icon: "person.crop.circle.badge.checkmark",
                        text: "Quick and easy sign in",
                        color: FanChatTheme.neonGreen
                    )

                    FeatureHighlight(
                        icon: "eye.slash.fill",
                        text: "Your identity stays private",
                        color: FanChatTheme.neonPurple
                    )

                    FeatureHighlight(
                        icon: "sportscourt.fill",
                        text: "Join the conversation",
                        color: FanChatTheme.neonOrange
                    )
                }
                .padding(.horizontal, 40)
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 30)

                Spacer()

                // Sign in button (placeholder for future auth implementation)
                VStack(spacing: 16) {
                    Button(action: {
                        authService.signIn()
                    }) {
                        Text("Get Started")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Color.white)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal, 24)

                    // Loading indicator
                    if authService.isLoading {
                        HStack(spacing: 8) {
                            CasinoSpinner()
                                .scaleEffect(0.6)
                            Text("Signing in...")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(FanChatTheme.textSecondary)
                        }
                    }
                }
                .opacity(showContent ? 1 : 0)
                .offset(y: showContent ? 0 : 30)

                // Terms
                Text("By signing in, you agree to our Terms of Service and Privacy Policy")
                    .font(.system(size: 11))
                    .foregroundColor(FanChatTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                    .opacity(showContent ? 1 : 0)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) {
                showContent = true
            }
        }
        .onChange(of: authService.authState) { _, newState in
            if case .signedIn = newState {
                onSignIn()
            }
        }
        .alert("Sign In Error", isPresented: $showError) {
            Button("OK") {
                authService.errorMessage = nil
            }
        } message: {
            Text(authService.errorMessage ?? "An error occurred")
        }
        .onChange(of: authService.errorMessage) { _, newValue in
            showError = newValue != nil
        }
    }
}

// MARK: - Feature Highlight
struct FeatureHighlight: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(color)
                .frame(width: 28)
                .glow(color, radius: 4)

            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(FanChatTheme.textSecondary)

            Spacer()
        }
    }
}

#Preview {
    SignInView(authService: AuthenticationService.shared) {
        print("Signed in!")
    }
}
