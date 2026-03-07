import SwiftUI
import SwiftData
import ActivityKit
import WidgetKit

@main
struct SmartSpeedCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Global shared ViewModel
    @StateObject private var driveViewModel = DriveViewModel()
    
    var body: some Scene {
        WindowGroup {
            DriveRootView()
                .environmentObject(driveViewModel)
                // We use an explicit container for SwiftData persistence
                .modelContainer(for: [DriveSession.self, SpeedReading.self])
        }
    }
}
