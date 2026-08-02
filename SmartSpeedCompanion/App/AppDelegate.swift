import UIKit
import CarPlay
import FirebaseCore
import SwiftData
import Darwin // dlopen/dlclose for framework prewarming

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
    
    /// Pre-warm system frameworks that are cold-loaded lazily on first use.
    ///
    /// 1. WritingTools — on iOS 18+, UIKit checks WritingToolsSupport when a
    ///    text field gains focus, which triggers dlopen of WritingToolsUI →
    ///    GenerativeModels → GenerativeFunctionsFoundation. That cold-load can
    ///    block the main thread for 5+ seconds on older devices (see hang
    ///    report BFE0BF6A).
    /// 2. CoreHaptics — the July 27, 2026 5.4s touch hang report showed
    ///    `HapticDictionaryReader parseEvent:` (CoreHaptics) on the main
    ///    thread during gesture delivery. Pre-loading the framework off the
    ///    main thread means the first `CHHapticEngine()` (now lazily created
    ///    on first alert, see HapticAlertManager) never pays the dlopen cost
    ///    on the alert path.
    /// 3. TextInputCore / UIKit keyboard — the same July 27 report showed
    ///    `UIKBKeyplaneView` (keyboard plane) frames during touch delivery.
    ///    Touching these classes on a background queue warms the keyboard
    ///    stack so the first text-field focus / first keyboard appearance
    ///    doesn't cold-load it on the main thread.
    ///
    /// All warm-ups run on a utility background queue so they never block the
    /// main thread during launch.
    private func prewarmFrameworks() {
        DispatchQueue.global(qos: .utility).async {
            // NOTE: `NSClassFromString` does NOT trigger dlopen — it only
            // returns an already-registered class or nil, so touching the
            // class names alone would NOT load these frameworks. Use
            // `dlopen` to actually pull the dylibs into memory off the
            // main thread; `dlopen` is a no-op (returns an existing handle)
            // for frameworks that are already loaded and returns NULL
            // harmlessly if a path is wrong.
            //
            // RTLD_NOW (not RTLD_LAZY) so ALL symbol binding — the actual
            // cold-load cost — happens here on the background thread,
            // not lazily on the main thread on first use.
            //
            // 1. WritingTools stack (text-field focus stall — BFE0BF6A).
            dlopen("/System/Library/PrivateFrameworks/WritingToolsUI.framework/WritingToolsUI", RTLD_NOW)
            // 2. CoreHaptics (first-alert CHHapticEngine creation).
            dlopen("/System/Library/Frameworks/CoreHaptics.framework/CoreHaptics", RTLD_NOW)
            // 3. Keyboard / TextInputCore stack (first text-field focus).
            dlopen("/System/Library/PrivateFrameworks/TextInputCore.framework/TextInputCore", RTLD_NOW)
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