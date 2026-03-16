import SwiftUI
import SwiftData
import ActivityKit
import WidgetKit
import FirebaseCore

@main
struct SpeedSenseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Create shared container so background and app intents work smoothly
    let container: ModelContainer
    
    init() {
        // MUST be called before any static properties (like sharedAppState) are accessed
        FirebaseApp.configure()
        
        do {
            container = try ModelContainer(for: DriveSession.self, SpeedReading.self)
            AppDelegate.sharedDriveViewModel.sessionRecorder.setModelContext(container.mainContext)
        } catch {
            fatalError("Failed to initialize SwiftData model container.")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(AppDelegate.sharedAppState)
                .environmentObject(AppDelegate.sharedDriveViewModel)
                .modelContainer(container) // Share same exact container with SwiftData queries
        }
    }
}