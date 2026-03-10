import SwiftUI
import SwiftData
import ActivityKit
import WidgetKit
import FirebaseCore

@main
struct SmartSpeedCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        FirebaseApp.configure()
    }
    
    // Global shared ViewModel
    @StateObject private var driveViewModel = DriveViewModel()
    
    var body: some Scene {
        WindowGroup {
            DriveRootView()
                .environmentObject(driveViewModel)
                .preferredColorScheme(.dark)
                // We use an explicit container for SwiftData persistence
                .modelContainer(for: [DriveSession.self, SpeedReading.self, RoadSegment.self])
        }
    }
}
