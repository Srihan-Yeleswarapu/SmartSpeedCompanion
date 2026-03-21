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
                    VStack(spacing: 20) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 60))
                            .foregroundColor(DesignSystem.cyan)
                        
                        Text("SpeedSense")
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
            } else if !appState.authManager.isAuthenticated {
                AuthView()
            } else if !appState.hasSelectedState {
                StateSelectionView()
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
