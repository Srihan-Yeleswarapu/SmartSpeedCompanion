import UIKit
import CarPlay
import FirebaseCore
import SwiftData

class AppDelegate: UIResponder, UIApplicationDelegate {
    
    // Shared ModelContainer for SwiftData - initialized early so CarPlay can access it
    // This must be created before any scene (including CarPlay) connects
    static let sharedModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: DriveSession.self, SpeedReading.self)
        } catch {
            fatalError("Failed to create shared ModelContainer: \(error)")
        }
    }()
    
    // Shared ViewModel instance to pass to CarPlay
    // Uses the shared ModelContainer to ensure SessionRecorder has a valid context
    static let sharedDriveViewModel = DriveViewModel(modelContext: sharedModelContainer.mainContext)
    static let sharedAppState = AppState()
    
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        configureFirebase()
        return true
    }

    private func configureFirebase() {
        guard let options = FirebaseOptions(contentsOfFile: Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") ?? "") else {
            print("Firebase: GoogleService-Info.plist not found in bundle. Auth will fail.")
            return
        }
        FirebaseApp.configure(options: options)
        print("Firebase configured successfully.")
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