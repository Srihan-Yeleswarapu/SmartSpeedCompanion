import SwiftUI
import SwiftData
import ActivityKit
import WidgetKit
import FirebaseCore

@main
struct SpeedioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Use the shared ModelContainer from AppDelegate - it's already initialized
    // and available before any scene (including CarPlay) connects
    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(AppDelegate.sharedAppState)
                .environmentObject(AppDelegate.sharedDriveViewModel)
                .modelContainer(AppDelegate.sharedModelContainer)
                .preferredColorScheme(.dark)
        }
    }
}