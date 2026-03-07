import UIKit
import CarPlay

class AppDelegate: UIResponder, UIApplicationDelegate {
    
    // Shared ViewModel instance to pass to CarPlay
    // In a real app, this should be injected or handled via a shared container.
    // We expose it here for simplicity of connecting CPSceneDelegate to the same State.
    static let sharedDriveViewModel = DriveViewModel()
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
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
