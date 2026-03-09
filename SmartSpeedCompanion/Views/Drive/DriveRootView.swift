import SwiftUI
import MapKit

public struct DriveRootView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var driveViewModel: DriveViewModel
    
    public init() {}
    
    public var body: some View {
        TabView {
            MapWithHUDView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
            
            AnalyticsDashboardView()
                .tabItem {
                    Label("Analytics", systemImage: "chart.bar.fill")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .accentColor(Color(hex: "#00D4FF"))
        .toolbar(driveViewModel.isRecording || driveViewModel.isNavigating ? .hidden : .visible, for: .tabBar)
        .onAppear {
            driveViewModel.sessionRecorder.setModelContext(modelContext)
        }
    }
}
