import SwiftUI
import MapKit

public struct DriveRootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var driveViewModel: DriveViewModel

    public init() {}

    public var body: some View {
        TabView {
            MapWithHUDView()
                .environmentObject(driveViewModel)
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }

            AnalyticsDashboardView()
                .environmentObject(driveViewModel)
                .tabItem {
                    Label("Analytics", systemImage: "chart.bar.fill")
                }

            SettingsView()
                .environmentObject(driveViewModel)
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .accentColor(Color(hex: "#00D4FF"))
        .onAppear {
            driveViewModel.sessionRecorder.setModelContext(modelContext)
            SpeedLimitBrain.shared.modelContext = modelContext
            Task {
                await FirebaseSyncService.shared.syncVerified(
                    context: modelContext,
                    center: driveViewModel.locationManager.latestLocation?.coordinate ?? .init(latitude: 33.4, longitude: -111.9)
                )
            }
        }
    }
}
