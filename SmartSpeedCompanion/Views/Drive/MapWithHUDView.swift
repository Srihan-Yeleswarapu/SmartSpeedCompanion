import SwiftUI
import MapKit

public struct MapWithHUDView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass) var vSizeClass
    
    public init() {}
    
    private var isLandscape: Bool {
        // Simple heuristic: if vertical is compact, it's usually landscape on iPhone.
        return vSizeClass == .compact
    }
    
    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background map spanning entire screen
                LiveMapView()
                    .ignoresSafeArea(.all)
                
                // Overlay content
                VStack(spacing: 0) {
                    SearchBarView()
                        .padding(.top, 12) // Below status bar (handled by GeometryReader safe area in combination)
                        .padding(.horizontal, 16)
                    
                    Spacer()
                    
                    SpeedHUDPill(isLandscape: isLandscape)
                        .padding(.bottom, 16)
                }
                .padding(.top, geo.safeAreaInsets.top)
                .padding(.bottom, geo.safeAreaInsets.bottom)
            }
        }
    }
}

fileprivate struct SearchBarView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @State private var searchText = ""
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color(hex: "#00D4FF"))
                    .font(.system(size: 16, weight: .semibold))
                
                TextField("Search destination...", text: $searchText)
                    .foregroundColor(Color(hex: "#FFFFFF"))
                    .font(.system(size: 16))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit {
                        performSearch()
                    }
                
                if !searchText.isEmpty {
                    Button("Go") {
                        performSearch()
                    }
                    .foregroundColor(Color(hex: "#00D4FF"))
                    .font(.system(size: 16, weight: .bold))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Color(hex: "#0F1022").opacity(0.92))
            .cornerRadius(16)
            
            if !driveViewModel.searchResults.isEmpty {
                List(driveViewModel.searchResults, id: \.self) { item in
                    Button(action: {
                        Task {
                            await driveViewModel.startNavigation(to: item)
                            driveViewModel.searchResults.removeAll()
                            searchText = ""
                        }
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name ?? "Unknown Location")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(Color(hex: "#FFFFFF"))
                            
                            Text(item.placemark.title ?? "")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#8888AA"))
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color(hex: "#0F1022").opacity(0.92))
                }
                .listStyle(PlainListStyle())
                .frame(maxHeight: 300)
                .cornerRadius(16)
                .scrollContentBackground(.hidden)
            }
        }
    }
    
    private func performSearch() {
        Task {
            await driveViewModel.searchDestination(query: searchText)
        }
    }
}

fileprivate struct SpeedHUDPill: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    let isLandscape: Bool
    
    var body: some View {
        HStack(alignment: .center, spacing: isLandscape ? 12 : 24) {
            
            // Limit Sign
            LimitSignView(limit: driveViewModel.limit, source: driveViewModel.speedLimitSource, isLandscape: isLandscape)
            
            // Speed Number
            VStack(alignment: .leading, spacing: 0) {
                if driveViewModel.isRecording {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: "#FF3D71"))
                            .frame(width: 6, height: 6)
                            // Basic blink simulation using timer could be added here, keeping simple for now
                        Text("REC \(formatDuration(driveViewModel.sessionDuration))")
                            .font(.system(size: isLandscape ? 9 : 11, weight: .bold))
                            .foregroundColor(Color(hex: "#FF3D71"))
                    }
                    .padding(.bottom, 2)
                }
                
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(driveViewModel.speed))")
                        .font(.system(size: isLandscape ? 36 : 52, weight: .black, design: .rounded))
                        .foregroundColor(speedColor(status: driveViewModel.status))
                    
                    Text("MPH")
                        .font(.system(size: isLandscape ? 10 : 12, weight: .bold))
                        .foregroundColor(Color(hex: "#8888AA"))
                }
            }
            
            // Status Dot
            Circle()
                .fill(statusDotColor(status: driveViewModel.status))
                .frame(width: 14, height: 14)
                .shadow(color: statusDotColor(status: driveViewModel.status).opacity(0.5), radius: 6)
                // We pulse the scale when over
                .scaleEffect(driveViewModel.status == .over ? 1.4 : 1.0)
                .animation(driveViewModel.status == .over ? Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default, value: driveViewModel.status)
            
            // Start/Stop Button
            Button(action: {
                if driveViewModel.isRecording {
                    driveViewModel.endSession()
                } else {
                    driveViewModel.startSession()
                }
            }) {
                Text(driveViewModel.isRecording ? "STOP" : "START")
                    .font(.system(size: isLandscape ? 11 : 13, weight: .bold))
                    .foregroundColor(driveViewModel.isRecording ? .white : .black)
                    .frame(width: 72, height: 40)
                    .background(driveViewModel.isRecording ? Color(hex: "#FF3D71") : Color(hex: "#00D4FF"))
                    .cornerRadius(20)
            }
        }
        .padding(.horizontal, isLandscape ? 16 : 24)
        .padding(.vertical, isLandscape ? 12 : 16)
        .frame(minWidth: 340)
        .background(
            Color(hex: "#0F1022").opacity(0.95)
                .background(Material.ultraThinMaterial)
        )
        .cornerRadius(28)
        .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 10)
    }
    
    private func speedColor(status: SpeedStatus) -> Color {
        switch status {
        case .over: return Color(hex: "#FF3D71")
        case .warning: return Color(hex: "#FFB800")
        case .safe: return Color(hex: "#FFFFFF")
        }
    }
    
    private func statusDotColor(status: SpeedStatus) -> Color {
        switch status {
        case .over: return Color(hex: "#FF3D71")
        case .warning: return Color(hex: "#FFB800")
        case .safe: return Color(hex: "#00FF9D")
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let h = Int(duration) / 3600
        let m = (Int(duration) % 3600) / 60
        let s = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

fileprivate struct LimitSignView: View {
    let limit: Int
    let source: String
    let isLandscape: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: isLandscape ? 40 : 52, height: isLandscape ? 40 : 52)
                
                Circle()
                    .stroke(Color(hex: "#FF3D71"), lineWidth: 3)
                    .frame(width: isLandscape ? 40 : 52, height: isLandscape ? 40 : 52)
                
                VStack(spacing: 0) {
                    Text(limit == 0 ? "--" : "\(limit)")
                        .font(.system(size: isLandscape ? 16 : 20, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.top, isLandscape ? 2 : 4)
                    
                    Text("MPH")
                        .font(.system(size: isLandscape ? 7 : 9, weight: .black))
                        .foregroundColor(Color(hex: "#FF3D71"))
                        .padding(.bottom, isLandscape ? 4 : 6)
                }
            }
            
            Text(source == "OpenStreetMap" ? "OSM" : "EST")
                .font(.system(size: isLandscape ? 8 : 10, weight: .bold))
                .foregroundColor(source == "OpenStreetMap" ? Color(hex: "#00D4FF") : Color(hex: "#8888AA"))
        }
    }
}

fileprivate extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
