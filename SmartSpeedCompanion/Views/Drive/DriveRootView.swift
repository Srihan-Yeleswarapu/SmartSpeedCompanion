import SwiftUI
import MapKit

public struct DriveRootView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.modelContext) private var modelContext
    
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
            
            #if DEVELOPER_BUILD
            DeveloperTabView()
                .tabItem {
                    Label("Developer", systemImage: "terminal.fill")
                }
            #endif
        }
        .accentColor(Color(hex: "#00D4FF"))
        .alert("Short Drive Detected", isPresented: $driveViewModel.showShortSessionPrompt) {
            Button("Keep", role: .cancel) {
                driveViewModel.saveLastSession()
            }
            Button("Delete Drive", role: .destructive) {
                driveViewModel.deleteLastSession(context: modelContext)
            }
        } message: {
            Text("This drive was less than 1.5 minutes. Would you like to save it or delete it?")
        }
    }
}
