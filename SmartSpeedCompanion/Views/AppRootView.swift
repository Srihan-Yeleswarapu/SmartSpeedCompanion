import SwiftUI

public struct AppRootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var driveViewModel: DriveViewModel // Need this passed through down to DriveRootView if managed in SmartSpeedCompanionApp.
    
    public init() {}
    
    public var body: some View {
        Group {
            if !appState.authManager.initialAuthChecked {
                initializingView
            } else if !appState.hasSelectedState {
                // First-run funnel: state → onboarding → "how Speedio works" → tutorial → auth.
                // IMPORTANT: this branch is checked BEFORE `isAuthenticated` so that a
                // freshly signed-up account (for which `signUp` resets the funnel flags
                // to `false`) is routed into the funnel, not directly into Drive.
                StateSelectionView()
            } else if !appState.hasCompletedOnboarding {
                OnboardingView()
            } else if !appState.hasSeenTutorialTransition {
                TutorialTransitionView()
            } else if !appState.hasCompletedTutorial {
                TutorialView()
            } else {
                // Authentication is intentionally NOT a gate on the Drive UI (Apple
                // App Store Guideline 5.1.1(v): apps may not require users to register
                // to access features that aren't account-based — and the speedometer,
                // alerts, navigation, and CarPlay surface are local-first and free to
                // use). Every user — signed in or not — walks the same state →
                // onboarding → transition → tutorial → Drive funnel.
                //
                // Account code paths (`AuthenticationManager`, `AuthView`,
                // `SignInView`, `SignUpView`, Firestore sync, preference sync) are
                // intentionally NOT removed from the codebase; they're just not
                // surfaced here. The upcoming in-app-purchase rollout will reuse
                // them, and a returning user with a cached Firebase session can
                // still sign out / delete their account from Settings (gated on
                // `isAuthenticated`).
                DriveRootView()
                    .environmentObject(driveViewModel)
            }
        }
        // Track that the user has authenticated at least once on this device.
        // NOTE: today these modifiers are a forward-looking placeholder — the
        // `AuthView(defaultToSignUp: !appState.hasEverAuthenticated)` branch
        // that previously consumed this flag was removed when sign-up/sign-in
        // UI was hidden for Apple App Store Guideline 5.1.1(v). We still keep
        // the tracking because (a) Firebase auth state for any pre-existing
        // cached session still drives the Sign Out / Delete Account buttons in
        // Settings, and (b) the upcoming in-app-purchase rollout will re-surface
        // the auth UI here and re-consume `hasEverAuthenticated` as a
        // "returning vs. fresh" discriminator.
        //
        // The two captures below cover both timing cases:
        //   - .onAppear reads current values synchronously (the cold case where
        //     a returning user opens the app already signed in and SwiftUI's
        //     .onChange has no transition to observe).
        //   - .onChange covers any subsequent sign-in events that happen
        //     during this app session (e.g., a future auth-gated flow).
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
