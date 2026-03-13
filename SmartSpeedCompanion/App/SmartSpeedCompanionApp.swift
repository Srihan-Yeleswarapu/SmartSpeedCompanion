import SwiftUI
import SwiftData
import ActivityKit
import WidgetKit

@main
struct SpeedSenseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Create shared container so background and app intents work smoothly
    let container: ModelContainer
    
    init() {
        do {
            container = try ModelContainer(for: DriveSession.self, SpeedReading.self)
            AppDelegate.sharedDriveViewModel.sessionRecorder.setModelContext(container.mainContext)
        } catch {
            fatalError("Failed to initialize SwiftData model container.")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            DriveRootView()
                .environmentObject(AppDelegate.sharedDriveViewModel)
                .modelContainer(container) // Share same exact container with SwiftData queries
        }
    }
}
