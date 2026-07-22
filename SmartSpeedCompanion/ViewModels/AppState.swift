import SwiftUI
import Combine

public class AppState: ObservableObject {
    @AppStorage("hasCompletedOnboarding") public var hasCompletedOnboarding: Bool = false
    @AppStorage("hasCompletedTutorial") public var hasCompletedTutorial: Bool = false
    @AppStorage("hasSeenTutorialTransition") public var hasSeenTutorialTransition = false
    @AppStorage("hasSeenLocationPermission") public var hasSeenLocationPermission: Bool = false
    @AppStorage("hasSelectedState") public var hasSelectedState: Bool = false
    @AppStorage("userState") public var userState: String = ""
    // Persisted so we can present Sign In (instead of Sign Up) when a returning user signs out.
    @AppStorage("hasEverAuthenticated") public var hasEverAuthenticated: Bool = false
    
    @Published public var authManager = AuthenticationManager.shared
    
    // Relay changes from authManager to appState so views can react
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        authManager.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Setup preferences syncing listeners
        setupSettingsSync()

        // Account-creation hook: when `AuthenticationManager` posts
        // `.userDidSignUp` (after a successful email/password sign-up OR
        // first-time Apple Sign In, both of which create a new Firebase
        // Auth account), reset the onboarding funnel so the new account
        // is routed through state selection → survey → privacy
        // transition → feature tutorial rather than dropped straight into
        // the Drive tab. This is the *enforced* contract — handlers don't
        // have to remember, and any future sign-up path (SSO, magic link,
        // anonymous upgrade) that posts the notification gets the same
        // behavior for free.
        NotificationCenter.default.addObserver(
            forName: .userDidSignUp,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetOnboardingFunnel()
        }
    }

    /// Resets every onboarding-funnel flag back to its "fresh account"
    /// default. Call this right after a successful account-creation
    /// path (email/password sign-up, Apple Sign In first-time grant, etc.)
    /// so `AppRootView` routes the new account through the funnel (state
    /// selection → survey → privacy transition → feature tutorial)
    /// instead of dropping them straight into the Drive tab.
    ///
    /// `hasEverAuthenticated` is deliberately NOT reset — that flag is a
    /// device-level marker (used to default the post-funnel screen to
    /// Sign In vs Sign Up after sign-out) and must persist across
    /// accounts on the same device.
    ///
    /// Mutating `@AppStorage` properties (rather than writing to
    /// `UserDefaults` directly) causes SwiftUI to re-publish automatically
    /// on the next runloop — no manual observer wiring required, and no
    /// risk of the underlying key string drifting away from this
    /// declaration.
    @MainActor
    public func resetOnboardingFunnel() {
        hasSelectedState = false
        userState = ""
        hasCompletedOnboarding = false
        hasSeenTutorialTransition = false
        hasCompletedTutorial = false
        hasSeenLocationPermission = false
    }
    
    private func setupSettingsSync() {
        // Observe all critical settings keys in UserDefaults and push updates to Firestore
        let settingsKeys = [
            "userBuffer", "audioAlertsEnabled", 
            "voiceNavEnabled", "speedUnit", "avoidHighways", "measurementSystem"
        ]
        
        for _ in settingsKeys {
            UserDefaults.standard
                .publisher(for: \.self)
                .debounce(for: .seconds(2), scheduler: RunLoop.main) // Prevent spamming Firestore
                .sink { _ in
                    if AuthenticationManager.shared.isAuthenticated {
                        AuthenticationManager.shared.syncUserPreferences()
                    }
                }
                .store(in: &cancellables)
        }
    }
}

// Helper to make kvo observable standard keys if needed,
// though manual observation is often safer for UserDefaults.
extension UserDefaults {
    @objc var userBuffer: Double { double(forKey: "userBuffer") }
    @objc var audioAlertsEnabled: Bool { bool(forKey: "audioAlertsEnabled") }
    @objc var hapticsEnabled: Bool { bool(forKey: "hapticsEnabled") }
    @objc var voiceNavEnabled: Bool { bool(forKey: "voiceNavEnabled") }
    @objc var avoidHighways: Bool { bool(forKey: "avoidHighways") }
    @objc var speedUnit: String? { string(forKey: "speedUnit") }
    @objc var measurementSystem: String? { string(forKey: "measurementSystem") }
}

/// Posted by `AuthenticationManager` whenever a brand-new Firebase Auth
/// account is created (success branch of `signUp(...)` and the first-time
/// grant in `signInWithApple(...)`). `AppState` observes this on the main
/// queue and resets the onboarding funnel so the new account walks it
/// instead of landing directly in the Drive tab.
extension Notification.Name {
    static let userDidSignUp = Notification.Name("userDidSignUp")
}
