import UIKit
import CarPlay
import FirebaseCore

class AppDelegate: UIResponder, UIApplicationDelegate {
    
    // Shared ViewModel instance to pass to CarPlay
    // In a real app, this should be injected or handled via a shared container.
    // We expose it here for simplicity of connecting CPSceneDelegate to the same State.
    // Shared instance for phone + CarPlay
    static let sharedDriveViewModel = DriveViewModel()
    static let sharedAppState = AppState()
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        FirebaseApp.configure()
        return true
    }
    
    // Required for multi-scene support (iPhone + CarPlay)
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            return UISceneConfiguration(name: "CarPlay Configuration", sessionRole: connectingSceneSession.role)
        }
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}