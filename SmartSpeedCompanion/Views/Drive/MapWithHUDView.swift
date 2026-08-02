import SwiftUI
import MapKit

public struct MapWithHUDView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) var hSizeClass
    @Environment(\.verticalSizeClass) var vSizeClass
    // Observed so the offline banner re-renders in real time when
    // NWPathMonitor fires a path-update on the device. Per
    // TestFlight 2.1.4 feedback from
    // srihan.yeleswarapu@gmail.com: "if the user has no wifi, show an
    // alert saying please turn on WiFi or cellular data".
    @ObservedObject private var network = NetworkReachability.shared

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
                    // Top section — -20 offset lifts the search bar + 3D
                    // toggle up by 10 px more from the previous -10 position.
                    // TestFlight 2.2.0 (b397) follow-up from
                    // srihan.yeleswarapu@gmail.com: nearly there, just needed
                    // another 10 px up. The group offset is purely visual so
                    // the Spacer below still expands to fill the middle.
                    Group {
                        // Offline banner (TestFlight 2.1.4 feedback:
                    // "if the user has no wifi, show an alert saying
                    // please turn on WiFi or cellular data"). Visible only
                    // when NWPathMonitor reports !satisfied. Pinned to the
                    // very top of the VStack so it doesn't get occluded
                    // by navigation cards. Animates in/out so it doesn't
                    // punch in awkwardly when connectivity flaps.
                    if !network.isConnected {
                        OfflineDataBanner()
                            .padding(.top, geo.safeAreaInsets.top + 4)
                            .padding(.horizontal, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
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

                        // Look Around + Apple Maps shortcut row shown right
                        // under the navigation instruction card while we are
                        // actively navigating to a destination.
                        if driveViewModel.isNavigating, let dest = driveViewModel.destination {
                            NavigationShortcutsRow(destination: dest)
                                .padding(.top, 8)
                                .padding(.horizontal, 16)
                        }
                    } else {
                        // Top row (TestFlight 2.2.x chrome redesign).
                        //   • SearchBarView — thinner (inner HStack frame is
                        //     40pt, down from 56pt; magnifier is 16pt;
                        //     TextField is 15pt; inner padding is 14pt).
                        //   • MapPitchToggleButton — SwiftUI 2D/3D pill.
                        //     TestFlight FB28: user wants the 3D pill AND
                        //     the native compass/tracking buttons to
                        //     COLLAPSE while the search bar is focused so
                        //     the search row has full width and the map
                        //     has more room. Hiding the pill here makes
                        //     the search row visually read as one
                        //     [expanded search bar] until the user taps
                        //     away, at which point we restore the 3D pill.
                        //     The companion's MKCompassButton +
                        //     MKUserTrackingButton are hidden in
                        //     `LiveMapView.updateUIView` against the same
                        //     flag.
                        HStack(spacing: 8) {
                            SearchBarView(isLandscape: isLandscape)
                            if !driveViewModel.isSearchingLocally {
                                MapPitchToggleButton(isLandscape: isLandscape)
                                    .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: driveViewModel.isSearchingLocally)
                        .padding(.top, geo.safeAreaInsets.top + 8)
                        .padding(.horizontal, 12)
                    }

                    // NOTE: SpeedCameraAlertBanner removed — camera API is disabled.

                    // Nearby amenities sheet: results of an MKLocalSearch
                    // category query (gas/food/coffee/parking). Empty by default.
                    if !driveViewModel.nearbyAmenities.isEmpty {
                        NearbyAmenitiesCard()
                            .padding(.top, 8)
                            .padding(.horizontal, 16)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    } // Group — top section
                    .offset(y: -35)

                    Spacer()

                    // Bottom section — +45 offset nudges the speed readout /
                    // START button / limit sign down by 10 px more from the
                    // previous +35 position, per TestFlight 2.2.0 (b397)
                    // follow-up from srihan.yeleswarapu@gmail.com: just
                    // needed another 10 px down. The offset is purely
                    // visual so the Spacer above still expands to fill the
                    // middle.
                    Group {
                        // Re-center button — always visible when map is detached
                        if driveViewModel.isMapDetached {
                            HStack {
                                Button(action: {
                                    UISelectionFeedbackGenerator().selectionChanged()
                                    driveViewModel.isMapDetached = false
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "location.fill")
                                            .font(.system(size: 16, weight: .bold))
                                        Text("Re-center")
                                            .font(.system(size: 13, weight: .bold))
                                    }
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)                            .liquidGlassChip(cornerRadius: 20, tint: DesignSystem.cyan.opacity(0.06), interactive: true)
                            .shadow(color: DesignSystem.cyan.opacity(0.25), radius: 8)
                                }
                                .padding(.leading, 16)
                                .padding(.bottom, 8)
                                .transition(.scale.combined(with: .opacity))

                                Spacer()
                            }
                        }

                        if !driveViewModel.isSelectingRoute && !driveViewModel.isSearchingLocally {
                            // Bottom chrome redesign — NO panel background.
                            // The SpeedReadout (leading), START/STOP pill
                            // (center), and LimitSignView (trailing) are three
                            // independent floating widgets that just sit over
                            // the map; the road-name chip floats centered
                            // above them. All padding is handled internally by
                            // `BottomTransparentHUD` so the parent only sets
                            // safe-area + horizontal breathing room.
                            BottomTransparentHUD(isLandscape: isLandscape)
                                .padding(.horizontal, 16)
                                .padding(.bottom, geo.safeAreaInsets.bottom + 12)
                        }
                    } // Group — bottom section
                    .offset(y: 45)
                }
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.8), value: driveViewModel.isNavigating)
            .animation(.easeInOut(duration: 0.25), value: driveViewModel.isMapDetached)
            .animation(.easeInOut(duration: 0.3), value: driveViewModel.nearbyAmenities.count)
        }
        .onAppear {
            driveViewModel.loadNamedLocations(context: modelContext)
        }
        .sheet(isPresented: $driveViewModel.showNameLocationSheet) {
            NameLocationSheet()
                .environmentObject(driveViewModel)
                .presentationDetents([.height(400)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $driveViewModel.showRouteStopsSheet) {
            RouteStopsSheet()
                .environmentObject(driveViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(24)
                .preferredColorScheme(.dark)
        }
    }
}

fileprivate struct NavigationInstructionCard: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    
    var body: some View {
        VStack(spacing: 8) {
            // Main navigation info row
            HStack(spacing: 14) {
                // Maneuver Icon — fixed size, never overlaps text
                Image(systemName: driveViewModel.nextManeuverImageName)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(DesignSystem.cyan)
                    .frame(width: 54, height: 54)
                    .background(DesignSystem.cyan.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(width: 54, height: 54) // fixed size — never shrinks into text

                // Instruction text — gets all remaining space
                VStack(alignment: .leading, spacing: 3) {
                    Text(driveViewModel.nextManeuverInstruction.isEmpty ? "Follow the route" : driveViewModel.nextManeuverInstruction)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 6) {
                        Text(formatDistance(driveViewModel.distanceToNextTurn))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(DesignSystem.cyan)

                        if let eta = driveViewModel.eta {
                            Text("·")
                                .foregroundColor(.white.opacity(0.4))
                            Text("ETA \(eta, format: .dateTime.hour().minute())")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }

                    // Stops count badge
                    if !driveViewModel.routeStops.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 9))
                                .foregroundColor(DesignSystem.amber)
                            Text("\(driveViewModel.routeStops.count) stop\(driveViewModel.routeStops.count > 1 ? "s" : "") · \(totalViaTime)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DesignSystem.amber)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Dismiss button
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    Task { await driveViewModel.endNavigation() }
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(10)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, driveViewModel.routeStops.isEmpty ? 12 : 4)

            // Action buttons row (Add Stop + Stops list)
            HStack(spacing: 8) {
                // Add Stop button
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    driveViewModel.showRouteStopsSheet = true
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 10))
                        Text(driveViewModel.routeStops.isEmpty ? "Add Stop" : "Edit Stops")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .liquidGlassChip(cornerRadius: 12, tint: DesignSystem.cyan.opacity(0.08), interactive: true)
                }
                .buttonStyle(.plain)

                // Optimize button — only appears when there are 2+ stops to reorder
                if driveViewModel.routeStops.count >= 2 {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        driveViewModel.showRouteStopsSheet = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.swap")
                                .font(.system(size: 10))
                            Text("Optimize")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(DesignSystem.amber)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(DesignSystem.amber.opacity(0.25), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .liquidGlass(interactive: true)
    }

    private var totalViaTime: String {
        let total = driveViewModel.routeLegs.reduce(0) { $0 + $1.travelTime }
        let min = Int(total / 60)
        if min < 60 { return "\(min) min total" }
        return "\(min / 60)h \(min % 60)m total"
    }

    private func formatDistance(_ distance: CLLocationDistance) -> String {
        let system = UserDefaults.standard.string(forKey: "measurementSystem") ?? "Imperial"
        
        if system == "Metric" {
            if distance < 1000 {
                let rounded = Int(round(distance / 50.0) * 50)
                return "\(max(50, rounded)) m"
            } else {
                return String(format: "%.1f km", distance / 1000.0)
            }
        } else {
            let feet = distance * 3.28084
            if feet < 1000 {
                let rounded = Int(round(feet / 100.0) * 100)
                return "\(max(100, rounded)) ft"
            } else {
                let miles = distance * 0.000621371
                return String(format: "%.1f mi", miles)
            }
        }
    }
}

fileprivate struct SearchBarView: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    let isLandscape: Bool
    @State private var searchText = ""
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: isLandscape ? 6 : 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(DesignSystem.cyan)
                    .font(.system(size: isLandscape ? 12 : 14, weight: .bold))
                
                TextField("Where to?", text: $searchText)
                    .foregroundColor(.white)
                    .font(.system(size: isLandscape ? 12 : 14, weight: .medium))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
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
                        // Clear any proposed route alternatives + map polylines
                        // that were rendered for the previous search so they
                        // don't linger on the map after the user dismisses
                        // the search bar via the X button. TestFlight 2.2.0
                        // (b377) feedback from srihan.yeleswarapu@gmail.com:
                        // "When I 'X' out of the search, the directions
                        // options should also go away." Mirrors the dismissal
                        // logic in `RouteSelectionCard`'s own X handler so
                        // both dismiss paths reach the same end state
                        // (clear polylines, hide picker card, drop selected
                        // destination reference).
                        driveViewModel.isSelectingRoute = false
                        driveViewModel.availableRoutes = []
                        driveViewModel.destination = nil
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.4))
                            .font(.system(size: 12))
                    }
                }
            }
            .padding(.horizontal, isLandscape ? 10 : 12)
            .frame(height: isLandscape ? 36 : 48)
            .frame(maxWidth: isLandscape ? 360 : .infinity, alignment: .center)
            .liquidGlassChip(cornerRadius: isLandscape ? 10 : 14, tint: DesignSystem.cyan.opacity(0.04), interactive: true)
            
            if isFocused && !searchText.isEmpty {
                // Named locations section — only shown when actively typing.
                // TestFlight FB (srihan.yeleswarapu): "If I type something
                // into the search bar, and then backspace it completely,
                // then everything shows up!" Showing all saved locations
                // when the search field is empty overwhelmed the screen.
                // Gate on !searchText.isEmpty so the list only appears
                // when the user is actively filtering.
                let filteredNamed = driveViewModel.namedLocations.filter { $0.name.lowercased().contains(searchText.lowercased()) }
                
                if !filteredNamed.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("SAVED LOCATIONS")
                            .font(.system(size: 10, weight: .black))
                            .foregroundColor(DesignSystem.cyan.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                            .padding(.bottom, 8)
                        
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(filteredNamed.prefix(5)) { namedLoc in
                                    Button(action: {
                                        Task {
                                            let coord = CLLocationCoordinate2D(latitude: namedLoc.latitude, longitude: namedLoc.longitude)
                                            let placemark = MKPlacemark(coordinate: coord)
                                            let item = MKMapItem(placemark: placemark)
                                            item.name = namedLoc.name
                                            await driveViewModel.selectDestinationAndCalculateRoutes(to: item)
                                            searchText = ""
                                            isFocused = false
                                        }
                                    }) {
                                        HStack(spacing: 12) {
                                            ZStack {
                                                Image(systemName: "house.fill")
                                                    .font(.system(size: 12))
                                                    .foregroundColor(DesignSystem.cyan)
                                                Image(systemName: "tag.fill")
                                                    .font(.system(size: 6))
                                                    .foregroundColor(DesignSystem.amber)
                                                    .offset(x: 6, y: -6)
                                            }
                                            .frame(width: 24)
                                            
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(namedLoc.name)
                                                    .font(.system(size: 15, weight: .semibold))
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                if let addr = namedLoc.address, !addr.isEmpty {
                                                    Text(addr)
                                                        .font(.system(size: 11))
                                                        .foregroundColor(.white.opacity(0.45))
                                                        .lineLimit(1)
                                                }
                                            }
                                            
                                            Spacer()
                                            
                                            Image(systemName: "arrow.turn.up.right")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.white.opacity(0.3))
                                        }
                                        .padding(.vertical, 12)
                                        .padding(.horizontal, 16)
                                    }
                                    
                                    if namedLoc != filteredNamed.prefix(5).last {
                                        Divider()
                                            .background(Color.white.opacity(0.1))
                                            .padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                    .liquidGlass(cornerRadius: 16, interactive: true)
                    .padding(.top, 2)
                }
            }
            
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
                                    HStack(spacing: 0) {
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
                                        
                                        // X button to delete individual recent search entry
                                        Button(action: {
                                            driveViewModel.removeRecentSearch(search)
                                        }) {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.white.opacity(0.3))
                                                .padding(.trailing, 16)
                                                .padding(.vertical, 14)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    
                                    if search != filteredSearches.prefix(5).last {
                                        Divider()
                                            .background(Color.white.opacity(0.1))
                                            .padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                    .liquidGlass(cornerRadius: 16, interactive: true)
                    .padding(.top, 2)
                }
            }
            
            if !driveViewModel.searchCompletions.isEmpty && isFocused && !searchText.isEmpty {
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
                    .frame(maxHeight: 240)
                }
                .liquidGlass(cornerRadius: 16, interactive: true)
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

// MARK: - BottomTransparentHUD
//
// Replaces the legacy `SpeedHUDPill` (which forced all chrome into a
// single glass-frosted panel). User wanted three independent floating
// widgets so the map is fully visible underneath, so we DROP the
// `.glassStyle()` and let the HStack naturally space its children:
//   • [leading] SpeedReadout — huge speed number with status color, plus
//     the unit label and an optional REC indicator above.
//   • [center]  START/STOP pill — cyan capsule, red while recording.
//   • [trailing] LimitSignView — white-faced circle with red ring + the
//     small source-chip caption beneath.
//
// The road-name chip floats centered above the HStack, also no
// background. Each widget is a separate fileprivate struct so the layout
// can be tweaked individually in future iterations without churning the
// whole bottom chrome.
//
// `alignment: .bottom` makes the giant speed number "sit" on the same
// baseline as the smaller START button + smaller limit sign so the eye
// reads them as a single horizontal row even with NO panel backdrop
// holding them together.
fileprivate struct BottomTransparentHUD: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    let isLandscape: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Road name chip — glass chip floating centered above the HUD.
            // Hidden when nil (first 1-2 GPS ticks before the geocode resolves,
            // or after `clearNativeMapCache` runs at end-session, or on
            // a parking lot where geocode returns no thoroughfare).
            if let roadName = driveViewModel.currentRoadName, !roadName.isEmpty {
                Text(roadName.uppercased())
                    .font(.system(size: isLandscape ? 9 : 10, weight: .black, design: .monospaced))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .liquidGlassChip(cornerRadius: 8, tint: DesignSystem.cyan.opacity(0.03))
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            // Bottom row — three independent floating widgets over the map.
            // SpeedReadout (leading), START/STOP with Focus badge (center), LimitSignView (trailing).
            // The Focus button is overlaid on the top-trailing edge of the START/STOP capsule
            // so the original 3-column balance is preserved, even on narrow screens.
            HStack(alignment: .bottom, spacing: 0) {
                SpeedReadout(isLandscape: isLandscape)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Button(action: {
                    if driveViewModel.isRecording {
                        HapticAlertManager.playRecordingStopped()
                        driveViewModel.endSession()
                    } else {
                        HapticAlertManager.playRecordingStarted()
                        driveViewModel.startSession()
                    }
                }) {
                    ZStack(alignment: .topTrailing) {
                        Text(driveViewModel.isRecording ? "STOP" : "START")
                            .font(.system(size: isLandscape ? 12 : 14, weight: .black))
                            .foregroundColor(driveViewModel.isRecording ? .white : .black)
                            .frame(width: isLandscape ? 72 : 86, height: isLandscape ? 38 : 44)
                            .background(driveViewModel.isRecording ? DesignSystem.alertRed : DesignSystem.cyan)
                            .clipShape(Capsule())
                            .shadow(color: (driveViewModel.isRecording ? DesignSystem.alertRed : DesignSystem.cyan).opacity(0.4), radius: 10)
                        
                        // Focus Mode badge inset on the top-trailing edge of the capsule
                        Button(action: {
                            HapticAlertManager.playFocusModeEnter()
                            driveViewModel.isDriveFocusMode = true
                        }) {
                            Image(systemName: "eye.fill")
                                .font(.system(size: isLandscape ? 7 : 8, weight: .black))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Circle().fill(DesignSystem.cyan))
                                .overlay(Circle().stroke(Color.black, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain) // no double-highlight from nested buttons
                        .offset(x: 6, y: -6)
                    }
                }
                .offset(x: -30)
                .frame(maxWidth: .infinity, alignment: .center)
                LimitSignView(
                    limit: driveViewModel.limit,
                    source: driveViewModel.speedLimitSource,
                    isLandscape: isLandscape,
                    onTap: {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await driveViewModel.manualRefetchSpeedLimit() }
                    },
                    isRefreshing: driveViewModel.isRefreshingSpeedLimit
                )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        // NO .glassStyle() — each widget floats independently over the
        // map. Safe-area bottom inset is applied by the parent.
    }
}

// MARK: - SpeedReadout
//
// Floating speed-number widget extracted from the legacy `SpeedHUDPill`.
// Big rounded number in the live status color, plus the unit label
// (mph / kmh) on the right of the baseline, plus an optional REC
// indicator dot + timer on top so the user sees recording status at a
// glance. Lives on the leading edge of the bottom chrome row.
fileprivate struct SpeedReadout: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    let isLandscape: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if driveViewModel.isRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DesignSystem.alertRed)
                        .frame(width: 6, height: 6)
                    Text("REC \(recDuration)")
                        .font(.system(size: isLandscape ? 10 : 12, weight: .black))
                        .foregroundColor(DesignSystem.alertRed)
                }
                .padding(.bottom, 2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(driveViewModel.speed))")
                    .font(.system(size: isLandscape ? 52 : 64, weight: .black, design: .rounded))
                    .foregroundColor(DesignSystem.colorForStatus(driveViewModel.status))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .minimumScaleFactor(0.85)

                // Unit label honors Settings → UNITS so the speed
                // readout matches the LIMIT sign to its right.
                Text(SpeedFormatting.unitLabelShort(measurementSystem: SpeedFormatting.measurementSystem()))
                    .font(.system(size: isLandscape ? 12 : 14, weight: .black))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(minWidth: isLandscape ? 110 : 132, alignment: .leading)
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .padding(.vertical, 10)
    }

    /// Same `%H:%M:%S` formatting the legacy `SpeedHUDPill.formatDuration`
    /// used; lifted to a computed property because the speed readout is
    /// now its own View (was nested in `SpeedHUDPill` before).
    private var recDuration: String {
        let d = driveViewModel.sessionDuration
        let h = Int(d) / 3600
        let m = (Int(d) % 3600) / 60
        let s = Int(d) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - MapPitchToggleButton
//
// Tiny white pill rendered directly to the right of the search bar that
// cycles the user's pin for the MKMapView camera pitch through:
//   `.auto` → `.forced2D` → `.forced3D` → `.auto` → ...
//
// The white-on-black "AUTO / 2D / 3D" label stays readable against any
// map style. The full 44×44 capsule is the tap area (44×38 in landscape
// to fit the smaller search bar height).
//
// Sits next to the search bar because the native MKMapView pitch toggle
// is hidden (see `LiveMapView.makeUIView`); without this pill, the
// user would have no 2D / 3D switch at all.
fileprivate struct MapPitchToggleButton: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    let isLandscape: Bool

    var body: some View {
        Button(action: cycle) {
            Text(driveViewModel.mapPitchMode.shortLabel)
                .font(.system(size: isLandscape ? 11 : 12, weight: .black, design: .rounded))
                .foregroundColor(.black)
                .frame(width: isLandscape ? 38 : 44, height: isLandscape ? 38 : 44)
                .liquidGlassChip(cornerRadius: 10, tint: Color.white.opacity(0.40), interactive: true)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityLabel("Camera pitch: \(driveViewModel.mapPitchMode.shortLabel). Tap to cycle 2D, 3D, auto.")
    }

    private func cycle() {
        UISelectionFeedbackGenerator().selectionChanged()
        let all = DriveViewModel.MapPitchMode.allCases
        let idx = all.firstIndex(of: driveViewModel.mapPitchMode) ?? 0
        let next = all[(idx + 1) % all.count]
        driveViewModel.mapPitchMode = next
        DebugLogger.shared.log("MapPitch: \(next.rawValue)")
    }
}

fileprivate struct LimitSignView: View {
    let limit: Int
    let source: String
    let isLandscape: Bool
    /// User tapped the sign -> fire DriveViewModel.manualRefetchSpeedLimit().
    /// Passed as a closure so LimitSignView doesn't need an @EnvironmentObject
    /// chain (the parent already holds driveViewModel).
    let onTap: () -> Void
    /// True while a tap-driven refetch is in flight. Drives a subtle
    /// scale pulse so the user immediately sees their tap landed even
    /// when the fetched answer matches the old one.
    let isRefreshing: Bool

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: isLandscape ? 40 : 52, height: isLandscape ? 40 : 52)

                Circle()
                    .stroke(Color(hex: "#FF3D71"), lineWidth: 3)
                    .frame(width: isLandscape ? 40 : 52, height: isLandscape ? 40 : 52)

                VStack(spacing: 0) {
                    // LimitSignView is the most prominent speed-limit display
                    // in the app. Routes through `SpeedFormatting` so there's
                    // exactly one mph→display conversion path across the HUD,
                    // widget, Live Activity, and CarPlay. (TestFlight 2.1.4
                    // feedback: this view was already correct, but the inline
                    // conversion made future drift bugs easy.)
                    let limitUnit = SpeedFormatting.unitLabelShort(
                        measurementSystem: SpeedFormatting.measurementSystem()
                    )
                    let limitValue = SpeedFormatting.displayLimit(
                        forMph: limit,
                        measurementSystem: SpeedFormatting.measurementSystem()
                    )
                    Text(limit == 0 ? "--" : "\(limitValue)")
                        .font(.system(size: isLandscape ? 17 : 21, weight: .black))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(limitUnit)
                        .font(.system(size: isLandscape ? 7 : 9, weight: .black))
                        .foregroundColor(Color(hex: "#FF3D71"))
                }
                .offset(y: isLandscape ? -2 : -1)
            }
            .padding(6) // glass circle behind the limit sign
            .background(Circle().fill(Material.ultraThinMaterial))
            .clipShape(Circle())

            Text(sourceChip.text)
                .font(.system(size: isLandscape ? 8 : 10, weight: .bold))
                .foregroundColor(sourceChip.color)
            }
        }
        .buttonStyle(.plain)                  // keep flat aesthetic when not pressed
        .accessibilityLabel("Speed limit. Tap to refresh.")
        .scaleEffect(isRefreshing ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.25), value: isRefreshing)
    }

    /// Chip-style label + color for the active speed-limit source.
    /// Computed property (not `let`) so it stays legal inside `var body`'s @ViewBuilder.
    /// Keeps the legacy "DB"-keyed color when offline/SQLite is the source, distinguishes
    /// the two live network paths, and shows an unobtrusive grey when no data is available.
    private var sourceChip: (text: String, color: Color) {
        switch source {
        case "Live (ArcGIS)":   return ("ArcGIS", Color(hex: "#34D38A"))     // green = freshest
        case "Live (Overpass)": return ("OSM", Color(hex: "#00D4FF"))        // cyan = live but OSM-based
        case "DB":              return ("DB", DesignSystem.cyan)             // local fallback
        case "DB (Recovered)":  return ("DB (R)", DesignSystem.amber)        // expanded-search fallback
        default:                return ("--", Color(hex: "#8888AA"))         // No Data / unknown
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
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

            // SUBTITLE — explains the visual hierarchy to the user so
            // the picker card and the map's bold/light polyline
            // treatment agree. ("SUGGESTED" pill mirrors the bold cyan
            // line on the map; "ALTERNATE" mirrors the muted white
            // line.)
            HStack(spacing: 6) {
                Text("Bold line on map = the recommended route")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, -6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(Array(driveViewModel.availableRoutes.enumerated()), id: \.offset) { index, route in
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            Task {
                                await driveViewModel.startNavigation(with: route)
                            }
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                // Tag pill — SUGGESTED on routes[0] (the
                                // bold one), ALTERNATE on the rest. The
                                // pill itself is filled cyan on the
                                // recommended route and outlined on
                                // alternatives so the picker card
                                // visually mirrors the bold/light
                                // polylines on the map. Mirrors the
                                // same hierarchy so the user's eye
                                // doesn't have to reconcile two
                                // conflicting representations.
                                HStack(spacing: 6) {
                                    if index == 0 {
                                        Text("SUGGESTED")
                                            .font(.system(size: 9, weight: .black))
                                            .foregroundColor(.black)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(DesignSystem.cyan)
                                            .clipShape(Capsule())
                                    } else {
                                        Text("ALTERNATE")
                                            .font(.system(size: 9, weight: .black))
                                            .foregroundColor(.white.opacity(0.75))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .overlay(
                                                Capsule().stroke(Color.white.opacity(0.30), lineWidth: 1)
                                            )
                                    }
                                    Text("Route \(index + 1)")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.white.opacity(0.75))
                                }

                                Text("\(Int(route.expectedTravelTime / 60)) min")
                                    .font(.system(size: 22, weight: .black))
                                    .foregroundColor(index == 0 ? DesignSystem.cyan : .white)

                                Text(String(format: "%.1f mi", route.distance * 0.000621371))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            .padding(16)
                            .frame(width: 150, alignment: .leading)
                            .background(index == 0 ? Color.white.opacity(0.16) : Color.white.opacity(0.08))
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
        .liquidGlass(cornerRadius: 24, interactive: true)
    }
}

// MARK: - Navigation Shortcuts Row
//
// One pill button shown under the navigation card while a destination is
// active. It opens the RouteStopsSheet where the user can add, reorder, or
// delete intermediate waypoints.
fileprivate struct NavigationShortcutsRow: View {
    @EnvironmentObject var driveViewModel: DriveViewModel
    let destination: MKMapItem

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // Keep only the in-app stop action in this row. The external
                // Apple Maps handoff was a redundant button in the navigation
                // card and the latest TestFlight feedback explicitly asks for
                // it to be removed.
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    driveViewModel.showRouteStopsSheet = true
                }) {
                    Label("Add Stops", systemImage: "plus.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .foregroundColor(.white)
                        .liquidGlassChip(cornerRadius: 18, interactive: true)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Nearby Amenities Card
//
// Inline list of the most recent MKLocalSearch category results. Tapping a
// row either reroutes to that MKMapItem or hands it off to Apple Maps.
fileprivate struct NearbyAmenitiesCard: View {
    @EnvironmentObject var driveViewModel: DriveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(driveViewModel.nearbyAmenitiesQuery.uppercased())
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(DesignSystem.cyan)
                Spacer()
                Button(action: { driveViewModel.nearbyAmenities = [] }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            ForEach(Array(driveViewModel.nearbyAmenities.prefix(4).enumerated()), id: \.offset) { _, item in
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    driveViewModel.openInAppleMaps(item)
                    // Drop the rest of the list after handing one off to
                    // Apple Maps so it doesn't float over the map forever.
                    driveViewModel.nearbyAmenities = []
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(DesignSystem.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Unnamed place")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if let addr = item.placemark.title {
                                Text(addr)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.white.opacity(0.5))
                            .font(.system(size: 13))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                Divider().background(Color.white.opacity(0.1)).padding(.horizontal, 14)
            }

            Color.clear.frame(height: 8)
        }
        .padding(.vertical, 8)
        .liquidGlassChip(cornerRadius: 18, tint: DesignSystem.cyan.opacity(0.06), interactive: true)
    }
}

// MARK: - Offline Data Banner
// TestFlight 2.1.4 feedback from srihan.yeleswarapu@gmail.com: "if the
// user has no wifi, show an alert saying please turn on WiFi or
// cellular data". We surface a non-modal red banner at the top of the
// driving overlay whenever NWPathMonitor reports the path as !satisfied.
// The banner animates in / out so brief connectivity flaps don't punch
// in awkwardly.
fileprivate struct OfflineDataBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("OFFLINE")
                    .font(.system(size: 10, weight: .black))
                    .foregroundColor(.white.opacity(0.75))
                Text("Turn on Wi-Fi or Cellular Data for fresh speed limits.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(DesignSystem.alertRed.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: DesignSystem.alertRed.opacity(0.5), radius: 8, y: 2)
    }
}
