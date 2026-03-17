import SwiftUI
import Combine

public class AppState: ObservableObject {
    @AppStorage("hasCompletedOnboarding") public var hasCompletedOnboarding: Bool = false
    @AppStorage("hasCompletedTutorial") public var hasCompletedTutorial: Bool = false
    @AppStorage("hasSeenTutorialTransition") public var hasSeenTutorialTransition = false
    
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
