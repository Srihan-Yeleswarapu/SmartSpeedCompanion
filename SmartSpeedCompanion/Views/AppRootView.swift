import SwiftUI

public struct AppRootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var driveViewModel: DriveViewModel // Need this passed through down to DriveRootView if managed in SmartSpeedCompanionApp.
    
    public init() {}
    
    public var body: some View {
        Group {
            if !appState.authManager.initialAuthChecked {
                initializingView
            } else if appState.authManager.isAuthenticated {
                // Returning authenticated user: skip onboarding, go straight to Drive.
                DriveRootView()
                    .environmentObject(driveViewModel)
            } else if !appState.hasSelectedState {
                // First-run funnel: state → onboarding → "how Speedio works" → tutorial → auth.
                StateSelectionView()
            } else if !appState.hasCompletedOnboarding {
                OnboardingView()
            } else if !appState.hasSeenTutorialTransition {
                TutorialTransitionView()
            } else if !appState.hasCompletedTutorial {
                TutorialView()
            } else {
                // Just finished the first-run funnel — default to Sign Up for new users,
                // but to Sign In for anyone who has previously authenticated on this device.
                AuthView(defaultToSignUp: !appState.hasEverAuthenticated)
            }
        }
        // Track that the user has authenticated at least once, so a future sign-out
        // lands back on the Sign In tab (instead of refreshing Sign Up for returning users).
        // .onAppear reads current values (covers the cold-already-authenticated case
        // where SwiftUI's .onChange has no transition to observe).
        // .onChange covers any subsequent sign-in events during this session.
        .onAppear {
            if appState.authManager.initialAuthChecked && appState.authManager.isAuthenticated {
                appState.hasEverAuthenticated = true
            }
        }
        .onChange(of: appState.authManager.isAuthenticated) { _, isAuthed in
            if isAuthed {
                appState.hasEverAuthenticated = true
            }
        }
    }

    private var initializingView: some View {
        ZStack {
            DesignSystem.bgDeep.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "speedometer")
                    .font(.system(size: 60))
                    .foregroundColor(DesignSystem.cyan)

                Text("Speedio")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                ProgressView()
                    .tint(DesignSystem.cyan)
                    .scaleEffect(1.5)

                Text("Initializing...")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
}
