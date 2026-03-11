import SwiftUI
import SwiftData
import ActivityKit
import WidgetKit
import FirebaseCore

@main
struct SmartSpeedCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootDriveView()
                .preferredColorScheme(.dark)
                .modelContainer(for: [DriveSession.self, SpeedReading.self, RoadSegment.self])
        }
    }
}

private struct RootDriveView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        DriveRootView()
            .environmentObject(AppDelegate.sharedDriveViewModel)
            .onAppear {
                AppDelegate.sharedDriveViewModel.configureModelContext(modelContext)
            }
    }
}
