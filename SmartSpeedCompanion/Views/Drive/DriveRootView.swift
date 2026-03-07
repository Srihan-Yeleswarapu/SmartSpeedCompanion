import SwiftUI
import MapKit

public struct DriveRootView: View {
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
    }
}
