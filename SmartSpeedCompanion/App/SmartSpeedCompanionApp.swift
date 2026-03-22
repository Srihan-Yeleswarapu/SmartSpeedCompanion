import SwiftUI
import SwiftData
import ActivityKit
import WidgetKit
import FirebaseCore

@main
struct SpeedSenseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Create shared container so background and app intents work properly
    let container: ModelContainer?
    
    init() {
        // 1. MUST be called first to initialize Firebase
        FirebaseApp.configure()
        
        // 2. Initialize SwiftData
        do {
            let container = try ModelContainer(for: DriveSession.self, SpeedReading.self)
            self.container = container
            // Safely set the model context
            AppDelegate.sharedDriveViewModel.sessionRecorder.setModelContext(container.mainContext)
        } catch {
            print("CRITICAL: SwiftData Initialization Failed: \(error)")
            self.container = nil
        }
    }
    
    var body: some Scene {
        WindowGroup {
            if let container = container {
                AppRootView()
                    .environmentObject(AppDelegate.sharedAppState)
                    .environmentObject(AppDelegate.sharedDriveViewModel)
                    .modelContainer(container)
                    .preferredColorScheme(.dark)
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundColor(.red)
                    Text("Initialization Error")
                        .font(.headline)
                    Text("The app database could not be loaded. Please try again later.")
                        .font(.subheadline)
                        .padding()
                }
                .preferredColorScheme(.dark)
            }
        }
    }
}