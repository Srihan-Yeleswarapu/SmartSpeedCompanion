import UIKit
import CarPlay
import FirebaseCore
import SwiftData

class AppDelegate: UIResponder, UIApplicationDelegate {
    
    /// Controls the allowed interface orientations for the app.
    /// Set to `.all` when entering Drive Focus Mode (to allow landscape),
    /// and back to `.portrait` when exiting.
    static var orientationLock: UIInterfaceOrientationMask = .portrait
    
    // Shared ModelContainer for SwiftData - initialized early so CarPlay can access it
    // This must be created before any scene (including CarPlay) connects
    static let sharedModelContainer: ModelContainer = {
        do {
            return try ModelContainer(for: DriveSession.self, SpeedReading.self, NamedLocation.self, SpeedAlertProfile.self, VehicleProfile.self)
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
        prewarmFrameworks()
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
    
    /// Pre-warm system frameworks that are cold-loaded on first UITextField focus.
    /// On iOS 18+, UIKit checks WritingToolsSupport when a text field gains focus,
    /// which triggers dlopen of WritingToolsUI → GenerativeModels →
    /// GenerativeFunctionsFoundation. That cold-load can block the main thread
    /// for 5+ seconds on older devices (see hang report BFE0BF6A). Loading them
    /// early on a background queue avoids the stall during user interaction.
    private func prewarmFrameworks() {
        DispatchQueue.global(qos: .utility).async {
            _ = NSClassFromString("WritingToolsUI.WritingToolsViewController")
        }
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
    
    /// Dynamically returns the allowed interface orientations based on the current mode.
    /// Returns `.all` during Drive Focus Mode (allowing landscape rotation),
    /// and `.portrait` for all other screens.
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return Self.orientationLock
    }
}