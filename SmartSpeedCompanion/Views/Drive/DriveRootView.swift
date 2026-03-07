import SwiftUI

public struct DriveRootView: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @EnvironmentObject var viewModel: DriveViewModel
    
    @State private var selectedTab = 0
    
    public init() {}
    
    public var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: Map + Speed HUD (Companion Mode)
            CompanionDriveView()
                .tabItem {
                    Image(systemName: "map.fill")
                    Text("MAP")
                }
                .tag(0)
            
            // Tab 2: Analytics
            AnalyticsDashboardView()
                .tabItem {
                    Image(systemName: "chart.bar.fill")
                    Text("ANALYTICS")
                }
                .tag(1)
            
            // Tab 3: Settings
            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("SETTINGS")
                }
                .tag(2)
        }
        .tint(DesignSystem.cyan)
        .onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundColor = UIColor(DesignSystem.bgCard)
            
            UITabBar.appearance().standardAppearance = appearance
            if #available(iOS 15.0, *) {
                UITabBar.appearance().scrollEdgeAppearance = appearance
            }
        }
    }
}

fileprivate struct CompanionDriveView: View {
    @EnvironmentObject var viewModel: DriveViewModel
    
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Top 75% Map
                LiveMapView()
                    .frame(height: geo.size.height * 0.75)
                
                // Bottom 25% Speed HUD
                HStack(alignment: .center, spacing: 16) {
                    SpeedGaugeView()
                        .frame(width: 80, height: 80)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(Int(viewModel.speed))")
                            .font(DesignSystem.displayFont)
                            .scaleEffect(0.6, anchor: .leading)
                            .frame(height: 36)
                            .foregroundColor(.white)
                        
                        Text("MPH")
                            .font(.caption.bold())
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack {
                            Text("LIMIT \(viewModel.limit)")
                                .font(.caption.bold())
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
                        }
                        
                        Circle()
                            .fill(statusColor(viewModel.status))
                            .frame(width: 16, height: 16)
                            .shadow(color: statusColor(viewModel.status).opacity(0.5), radius: 4)
                    }
                }
                .padding()
                .frame(height: geo.size.height * 0.25)
                .background(DesignSystem.bgPanel)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
    
    private func statusColor(_ status: SpeedStatus) -> Color {
        switch status {
        case .over: return DesignSystem.alertRed
        case .warning: return DesignSystem.amber
        case .safe: return DesignSystem.neonGreen
        }
    }
}
