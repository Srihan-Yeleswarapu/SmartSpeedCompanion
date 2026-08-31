import SwiftUI
import MapKit

public struct DriveRootView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.modelContext) private var modelContext
    
    public init() {
        // Configure Tab Bar appearance for iOS 15+ to be opaque and styled
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(DesignSystem.bgPanel)
        appearance.backgroundEffect = UIBlurEffect(style: .systemThinMaterialDark)
        
        // Shadow for separation
        appearance.shadowColor = .white.withAlphaComponent(0.1)
        appearance.shadowImage = UIImage() // Removes the default thin line
        
        // Item styles for better contrast on Map
        let normal = appearance.stackedLayoutAppearance.normal
        normal.iconColor = UIColor.white.withAlphaComponent(0.35)
        normal.titleTextAttributes = [.foregroundColor: UIColor.white.withAlphaComponent(0.35)]
        
        let selected = appearance.stackedLayoutAppearance.selected
        selected.iconColor = UIColor(DesignSystem.cyan)
        selected.titleTextAttributes = [.foregroundColor: UIColor(DesignSystem.cyan)]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    
    public var body: some View {
        TabView {
            MapWithHUDView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .toolbarBackground(DesignSystem.bgPanel, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            
            AnalyticsDashboardView()
                .tabItem {
                    Label("Analytics", systemImage: "chart.bar.fill")
                }
                .toolbarBackground(DesignSystem.bgPanel, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .toolbarBackground(DesignSystem.bgPanel, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
        .toolbarColorScheme(.dark, for: .tabBar)
        .accentColor(Color(hex: "#00D4FF"))
        .onAppear {
            driveViewModel.loadVehicleProfiles(context: modelContext)
            driveViewModel.loadOfflineRegions()
            driveViewModel.loadNamedLocations(context: modelContext)
            // Check for an interrupted session from a previous launch
            driveViewModel.checkForInterruptedSession()
        }
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
        // Recovery alert for interrupted sessions (app was terminated mid-drive)
        .alert("Interrupted Drive Found", isPresented: $driveViewModel.showInterruptedSessionPrompt) {
            Button("Restore \(driveViewModel.interruptedSessionDestinationName)") {
                driveViewModel.restoreInterruptedSession()
            }
            Button("Discard", role: .destructive) {
                driveViewModel.discardInterruptedSession()
            }
        } message: {
            Text("It looks like you were in the middle of \(driveViewModel.interruptedSessionDestinationName) when the app was last closed. Would you like to resume or discard it?")
        }
        // Full-screen cover for Drive Focus Mode — distraction-free speed display
        .fullScreenCover(isPresented: $driveViewModel.isDriveFocusMode) {
            DriveFocusView()
                .environmentObject(driveViewModel)
        }
    }
}