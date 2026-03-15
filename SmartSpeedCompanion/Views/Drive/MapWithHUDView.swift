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
                    if (driveViewModel.isNavigating || driveViewModel.isSelectingRoute) && !driveViewModel.isSearchingLocally {
                        if driveViewModel.isNavigating {
                            NavigationInstructionCard()
                                .padding(.top, geo.safeAreaInsets.top + 8)
                                .padding(.horizontal, 16)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        } else if driveViewModel.isSelectingRoute {
                            RouteSelectionCard()
                                .padding(.top, geo.safeAreaInsets.top + 12)
                                .padding(.horizontal, 16)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    } else {
                        SearchBarView()
                            .padding(.top, geo.safeAreaInsets.top + 12)
                            .padding(.horizontal, 16)
                    }
                    
                    if let camera = driveViewModel.activeCameraAlert, !driveViewModel.isSearchingLocally {
                        SpeedCameraAlertBanner(camera: camera)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    
                    Spacer()
                    
                    if driveViewModel.isMapDetached {
                        HStack {
                            Button(action: {
                                driveViewModel.isMapDetached = false
                            }) {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 48, height: 48)
                                    .glassStyle(cornerRadius: 24)
                                    .shadow(color: DesignSystem.cyan.opacity(0.3), radius: 10)
                            }
                            .padding(.leading, 16)
                            .padding(.bottom, 8)
                            .transition(.scale.combined(with: .opacity))
                            
                            Spacer()
                        }
                    }
                    
                    if !driveViewModel.isSelectingRoute && !driveViewModel.isSearchingLocally {
                        SpeedHUDPill(isLandscape: isLandscape)
                            .padding(.bottom, geo.safeAreaInsets.bottom + 16)
                    }
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
                Text(driveViewModel.nextManeuverInstruction)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                
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
                driveViewModel.isSearchingLocally = true
            }) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(10)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }

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
        let system = UserDefaults.standard.string(forKey: "measurementSystem") ?? "Imperial"
        
        if system == "Metric" {
            if distance < 1000 {
                return "\(Int(distance)) m"
            } else {
                return String(format: "%.1f km", distance / 1000.0)
            }
        } else {
            // Imperial
            let feet = distance * 3.28084
            if feet < 1000 {
                return "\(Int(feet)) ft"
            } else if feet < 5280 {
                let yards = feet / 3
                return "\(Int(yards)) yd"
            } else {
                let miles = distance * 0.000621371
                return String(format: "%.1f mi", miles)
            }
        }
    }
}

fileprivate struct SearchBarView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @State private var searchText = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 6) {
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
                    .onChange(of: isFocused) { _, newValue in
                        driveViewModel.isSearchingLocally = newValue
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
            
            if isFocused && !driveViewModel.recentSearches.isEmpty {
                let filteredSearches = searchText.isEmpty ? driveViewModel.recentSearches : driveViewModel.recentSearches.filter { $0.lowercased().contains(searchText.lowercased()) }
                
                if !filteredSearches.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(searchText.isEmpty ? "RECENT SEARCHES" : "MATCHING RECENT")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(filteredSearches.prefix(5), id: \.self) { search in
                                    Button(action: {
                                        searchText = search
                                        Task {
                                            await driveViewModel.searchDestination(query: search)
                                            if let item = driveViewModel.searchResults.first {
                                                await driveViewModel.selectDestinationAndCalculateRoutes(to: item)
                                                searchText = ""
                                                isFocused = false
                                            }
                                        }
                                    }) {
                                        HStack {
                                            Image(systemName: "clock.arrow.circlepath")
                                                .font(.system(size: 14))
                                                .foregroundColor(DesignSystem.cyan)
                                            
                                            Text(search)
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundColor(.white)
                                            
                                            Spacer()
                                        }
                                        .padding(.vertical, 14)
                                        .padding(.horizontal, 16)
                                    }
                                    
                                    if search != filteredSearches.prefix(5).last {
                                        Divider()
                                            .background(Color.white.opacity(0.1))
                                            .padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 240)
                    }
                    .glassStyle(cornerRadius: 16)
                    .padding(.top, 2)
                }
            }
            
            if !driveViewModel.searchCompletions.isEmpty && isFocused {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(driveViewModel.searchCompletions, id: \.self) { completion in
                                Button(action: {
                                    Task {
                                        await driveViewModel.selectCompletion(completion)
                                        if let item = driveViewModel.searchResults.first {
                                            await driveViewModel.selectDestinationAndCalculateRoutes(to: item)
                                            searchText = ""
                                            isFocused = false
                                        }
                                    }
                                }) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(completion.title)
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                        
                                        Spacer()
                                        
                                        if !completion.subtitle.isEmpty {
                                            Text(completion.subtitle)
                                                .font(.system(size: 11))
                                                .foregroundColor(.white.opacity(0.4))
                                                .lineLimit(1)
                                                .frame(maxWidth: 160, alignment: .trailing)
                                        }
                                    }
                                    .padding(.vertical, 14)
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
                    .frame(maxHeight: 320)
                }
                .glassStyle(cornerRadius: 16)
                .padding(.top, 2)
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
            
            // Show route options for the first finding
            if let firstItem = driveViewModel.searchResults.first {
                await driveViewModel.selectDestinationAndCalculateRoutes(to: firstItem)
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
                    
                    Text(UserDefaults.standard.string(forKey: "measurementSystem") == "Metric" ? "KMH" : "MPH")
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
                    let isMetric = UserDefaults.standard.string(forKey: "measurementSystem") == "Metric"
                    let displayLimit = isMetric ? Int(Double(limit) * 1.60934) : limit
                    Text(limit == 0 ? "--" : "\(displayLimit)")
                        .font(.system(size: isLandscape ? 17 : 21, weight: .black))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    
                    Text(UserDefaults.standard.string(forKey: "measurementSystem") == "Metric" ? "KMH" : "MPH")
                        .font(.system(size: isLandscape ? 7 : 9, weight: .black))
                        .foregroundColor(Color(hex: "#FF3D71"))
                }
                .offset(y: isLandscape ? -2 : -1)
            }
            
            Text(source == "OpenStreetMap" ? "OSM" : "EST")
                .font(.system(size: isLandscape ? 8 : 10, weight: .bold))
                .foregroundColor(source == "OpenStreetMap" ? Color(hex: "#00D4FF") : Color(hex: "#8888AA"))
        }
    }
}

fileprivate struct SpeedCameraAlertBanner: View {
    let camera: SpeedCamera
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(hex: "#FF3D71")))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("SPEED CAMERA AHEAD")
                    .font(.system(size: 14, weight: .black))
                    .foregroundColor(Color(hex: "#FF3D71"))
                
                Text(camera.location ?? camera.roadway ?? "Unknown Location")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassStyle(cornerRadius: 16)
    }
}

fileprivate struct RouteSelectionCard: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Select Route")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    driveViewModel.isSelectingRoute = false
                    driveViewModel.availableRoutes = []
                    driveViewModel.destination = nil
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(driveViewModel.availableRoutes.enumerated()), id: \.offset) { index, route in
                        Button(action: {
                            Task {
                                await driveViewModel.startNavigation(with: route)
                            }
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Route \(index + 1)")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                
                                Text("\(Int(route.expectedTravelTime / 60)) min")
                                    .font(.system(size: 20, weight: .black))
                                    .foregroundColor(DesignSystem.cyan)
                                
                                Text(String(format: "%.1f mi", route.distance * 0.000621371))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .padding(16)
                            .frame(width: 140, alignment: .leading)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(16)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(DesignSystem.cyan.opacity(index == 0 ? 1 : 0), lineWidth: 2)
                            )
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .glassStyle(cornerRadius: 24)
    }
}
