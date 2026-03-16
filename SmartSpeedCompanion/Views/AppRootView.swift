import SwiftUI

public struct AppRootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var driveViewModel: DriveViewModel // Need this passed through down to DriveRootView if managed in SmartSpeedCompanionApp.
    
    public init() {}
    
    public var body: some View {
        Group {
            if !appState.authManager.initialAuthChecked {
                ZStack {
                    DesignSystem.bgDeep.ignoresSafeArea()
                    ProgressView()
                        .tint(DesignSystem.cyan)
                }
            } else if !appState.authManager.isAuthenticated {
                AuthView()
            } else if !appState.hasCompletedOnboarding {
                OnboardingView()
            } else if !appState.hasSeenTutorialTransition {
                TutorialTransitionView()
            } else if !appState.hasCompletedTutorial {
                TutorialView()
            } else {
                DriveRootView()
                    .environmentObject(driveViewModel)
            }
        }
    }
}
