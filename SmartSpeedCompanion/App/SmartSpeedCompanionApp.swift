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

    @State private var driveViewModel: DriveViewModel?

    var body: some Scene {
        WindowGroup {
            DriveViewProvider(driveViewModel: $driveViewModel)
                .preferredColorScheme(.dark)
                .modelContainer(for: [DriveSession.self, SpeedReading.self, RoadSegment.self])
        }
    }
}

private struct DriveViewProvider: View {
    @Environment(\.modelContext) private var modelContext
    @Binding var driveViewModel: DriveViewModel?

    var body: some View {
        Group {
            if let driveViewModel {
                DriveRootView()
                    .environmentObject(driveViewModel)
            } else {
                Color.clear
                    .task {
                        guard driveViewModel == nil else { return }
                        driveViewModel = DriveViewModel(modelContext: modelContext)
                    }
            }
        }
    }
}
