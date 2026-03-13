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
                    if driveViewModel.isNavigating {
                        NavigationInstructionCard()
                            .padding(.top, geo.safeAreaInsets.top + 8)
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else {
                        SearchBarView()
                            .padding(.top, geo.safeAreaInsets.top + 12)
                            .padding(.horizontal, 16)
                    }
                    
                    Spacer()
                    
                    SpeedHUDPill(isLandscape: isLandscape)
                        .padding(.bottom, geo.safeAreaInsets.bottom + 16)
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: driveViewModel.isNavigating)
        }
    }
}

fileprivate struct NavigationInstructionCard: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    
    var body: some View {
        HStack(spacing: 20) {
            // Maneuver Icon
            Image(systemName: driveViewModel.nextManeuverImageName)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(DesignSystem.cyan)
                .frame(width: 60, height: 60)
                .background(DesignSystem.cyan.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(driveViewModel.nextManeuverInstruction.uppercased())
                    .font(.system(size: 18, weight: .black))
                    .foregroundColor(.white)
                    .lineLimit(2)
                
                HStack(spacing: 8) {
                    Text(formatDistance(driveViewModel.distanceToNextTurn))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(DesignSystem.cyan)
                    
                    if let eta = driveViewModel.eta {
                        Text("•")
                            .foregroundColor(.white.opacity(0.4))
                        Text("ETA \(eta, format: .dateTime.hour().minute())")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            
            Spacer()
            
            Button(action: {
                Task { await driveViewModel.endNavigation() }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(10)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
        }
        .glassStyle()
    }
    
    private func formatDistance(_ distance: CLLocationDistance) -> String {
        if distance < 100 {
            return "\(Int(distance)) m"
        } else if distance < 1000 {
            return "\(Int(distance)) m"
        } else {
            return String(format: "%.1f km", distance / 1000.0)
        }
    }
}

fileprivate struct SearchBarView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @State private var searchText = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(DesignSystem.cyan)
                    .font(.system(size: 18, weight: .bold))
                
                TextField("Where to?", text: $searchText)
                    .foregroundColor(.white)
                    .font(.system(size: 17, weight: .medium))
                    .focused($isFocused)
                    .submitLabel(.search)
                    .onSubmit {
                        executeSubmitSearch()
                    }
                    .onChange(of: searchText) { _, newValue in
                        driveViewModel.updateSearchQuery(newValue)
                    }
                
                if !searchText.isEmpty {
                    Button(action: { 
                        searchText = ""
                        driveViewModel.updateSearchQuery("")
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .glassStyle()
            
            if !driveViewModel.searchCompletions.isEmpty && isFocused {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(driveViewModel.searchCompletions, id: \.self) { completion in
                                Button(action: {
                                    Task {
                                        await driveViewModel.selectCompletion(completion)
                                        if let item = driveViewModel.searchResults.first {
                                            await driveViewModel.startNavigation(to: item)
                                            searchText = ""
                                            isFocused = false
                                        }
                                    }
                                }) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(completion.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.white)
                                        
                                        if !completion.subtitle.isEmpty {
                                            Text(completion.subtitle)
                                                .font(.system(size: 13))
                                                .foregroundColor(.white.opacity(0.5))
                                        }
                                    }
                                    .padding(.vertical, 12)
                                    .padding(.horizontal, 16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                
                                if completion != driveViewModel.searchCompletions.last {
                                    Divider()
                                        .background(Color.white.opacity(0.1))
                                        .padding(.horizontal, 16)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                }
                .glassStyle()
                .padding(.top, 4)
            }
        }
    }
    
    private func executeSubmitSearch() {
        Task {
            // If completions are available, take the first one
            if let firstCompletion = driveViewModel.searchCompletions.first {
                await driveViewModel.selectCompletion(firstCompletion)
            } else if !searchText.isEmpty {
                // Otherwise do a natural language search
                await driveViewModel.searchDestination(query: searchText)
            }
            
            // Start navigation to the first finding
            if let firstItem = driveViewModel.searchResults.first {
                await driveViewModel.startNavigation(to: firstItem)
                searchText = ""
                isFocused = false
            }
        }
    }
}

fileprivate struct SpeedHUDPill: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    let isLandscape: Bool
    
    var body: some View {
        HStack(alignment: .center, spacing: isLandscape ? 16 : 24) {
            
            // Limit Sign
            LimitSignView(limit: driveViewModel.limit, source: driveViewModel.speedLimitSource, isLandscape: isLandscape)
            
            // Speed Number
            VStack(alignment: .leading, spacing: 0) {
                if driveViewModel.isRecording {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(DesignSystem.alertRed)
                            .frame(width: 6, height: 6)
                        Text("REC \(formatDuration(driveViewModel.sessionDuration))")
                            .font(.system(size: isLandscape ? 10 : 12, weight: .black))
                            .foregroundColor(DesignSystem.alertRed)
                    }
                    .padding(.bottom, 2)
                }
                
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(driveViewModel.speed))")
                        .font(.system(size: isLandscape ? 44 : 56, weight: .black, design: .rounded))
                        .foregroundColor(DesignSystem.colorForStatus(driveViewModel.status))
                        .contentTransition(.numericText())
                    
                    Text("MPH")
                        .font(.system(size: isLandscape ? 12 : 14, weight: .black))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            
            Spacer(minLength: 0)
            
            // Start/Stop Button
            Button(action: {
                if driveViewModel.isRecording {
                    driveViewModel.endSession()
                } else {
                    driveViewModel.startSession()
                }
            }) {
                Text(driveViewModel.isRecording ? "STOP" : "START")
                    .font(.system(size: isLandscape ? 12 : 14, weight: .black))
                    .foregroundColor(driveViewModel.isRecording ? .white : .black)
                    .frame(width: 80, height: 44)
                    .background(driveViewModel.isRecording ? DesignSystem.alertRed : DesignSystem.cyan)
                    .cornerRadius(22)
                    .shadow(color: (driveViewModel.isRecording ? DesignSystem.alertRed : DesignSystem.cyan).opacity(0.4), radius: 10)
            }
        }
        .padding(.horizontal, isLandscape ? 20 : 24)
        .padding(.vertical, isLandscape ? 14 : 18)
        .frame(minWidth: 320)
        .glassStyle()
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
