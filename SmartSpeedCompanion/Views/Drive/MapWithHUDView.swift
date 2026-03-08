// MapWithHUDView.swift
// Smart Speed Companion — Map Tab
//
// This is the primary driving screen. It combines a full-screen MKMapView
// (same engine as Apple Maps) with a floating speed HUD pill at the bottom
// and a search bar at the top. Written by hand — do not modify this file.

import SwiftUI
import MapKit
import Combine

// MARK: - Main Container View

struct MapWithHUDView: View {
    @EnvironmentObject var vm: DriveViewModel
    @StateObject private var crowdsourceService = CrowdsourceSpeedLimitService.shared

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {

                // ── 1. Full-screen map (bleeds under status bar + home indicator)
                MapView()
                    .environmentObject(vm)
                    .ignoresSafeArea(.all)

                // ── 2. Search bar pinned to top, inside safe area
                VStack(spacing: 0) {
                    SearchBarWithResults()
                        .environmentObject(vm)
                        .padding(.horizontal, 12)
                        .padding(.top, geo.safeAreaInsets.top + 8)
                    Spacer()
                }

                // ── 3. HUD pill pinned to bottom, above tab bar
                VStack {
                    Spacer()
                    SpeedHUDPill()
                        .environmentObject(vm)
                        .padding(.horizontal, 16)
                        .padding(.bottom, geo.safeAreaInsets.bottom + 72) // 72 = tab bar height
                }
                
                if crowdsourceService.showCrowdsourcePrompt {
                    CrowdsourceOverlayView()
                        .environmentObject(crowdsourceService)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(10)
                }
            }
            .animation(.spring(response: 0.3), value: crowdsourceService.showCrowdsourcePrompt)
        }
        .background(Color(hex: "#040510"))
    }
}

// MARK: - MKMapView Wrapper

struct MapView: UIViewRepresentable {
    @EnvironmentObject var vm: DriveViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(vm: vm)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        context.coordinator.mapView = map

        // Appearance
        map.overrideUserInterfaceStyle = .dark
        map.mapType = .standard
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.isRotateEnabled = true
        map.isPitchEnabled = false  // keep 2D — less disorienting while driving

        // Track user by default
        map.setUserTrackingMode(.followWithHeading, animated: false)

        // Compass button repositioned below search bar
        map.showsCompass = false // we add a custom one to avoid overlap
        let compass = MKCompassButton(mapView: map)
        compass.compassVisibility = .adaptive
        compass.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(compass)
        NSLayoutConstraint.activate([
            compass.topAnchor.constraint(equalTo: map.topAnchor, constant: 120),
            compass.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -12)
        ])

        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.updateRoute(on: map)
        context.coordinator.updateTracking(on: map)
    }

    // MARK: Coordinator
    final class Coordinator: NSObject, MKMapViewDelegate {
        let vm: DriveViewModel
        weak var mapView: MKMapView?
        private var cancellables = Set<AnyCancellable>()
        private var currentPolyline: MKPolyline?
        private var destinationAnnotation: MKPointAnnotation?

        // Prevent zoom fighting — only re-center when user hasn't touched the map
        var userInteracting = false

        init(vm: DriveViewModel) {
            self.vm = vm
            super.init()

            // Listen for route changes
            vm.$currentRoute
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let map = self?.mapView else { return }
                    self?.updateRoute(on: map)
                }
                .store(in: &cancellables)

            // Listen for navigation end
            vm.$isNavigating
                .receive(on: RunLoop.main)
                .sink { [weak self] navigating in
                    if !navigating {
                        self?.clearNavigation()
                    }
                }
                .store(in: &cancellables)
        }

        func updateRoute(on map: MKMapView) {
            // Clear old route
            if let old = currentPolyline {
                map.removeOverlay(old)
                currentPolyline = nil
            }
            if let old = destinationAnnotation {
                map.removeAnnotation(old)
                destinationAnnotation = nil
            }

            guard let route = vm.currentRoute else { return }

            // Draw new route polyline
            let polyline = route.polyline
            currentPolyline = polyline
            map.addOverlay(polyline, level: .aboveRoads)

            // Destination pin
            if let dest = vm.destination {
                let ann = MKPointAnnotation()
                ann.coordinate = dest.placemark.coordinate
                ann.title = dest.name
                destinationAnnotation = ann
                map.addAnnotation(ann)
            }

            // Fit route in view with padding (only when navigation just started)
            let padding = UIEdgeInsets(top: 120, left: 40, bottom: 220, right: 40)
            map.setVisibleMapRect(route.polyline.boundingMapRect,
                                  edgePadding: padding,
                                  animated: true)
        }

        func updateTracking(on map: MKMapView) {
            // When navigating, follow with heading
            // When idle and user hasn't interacted, follow with heading
            if !userInteracting {
                let desired: MKUserTrackingMode = .followWithHeading
                if map.userTrackingMode != desired {
                    map.setUserTrackingMode(desired, animated: true)
                }
            }
        }

        func clearNavigation() {
            guard let map = mapView else { return }
            if let p = currentPolyline { map.removeOverlay(p); currentPolyline = nil }
            if let a = destinationAnnotation { map.removeAnnotation(a); destinationAnnotation = nil }
            map.setUserTrackingMode(.followWithHeading, animated: true)
        }

        // MARK: MKMapViewDelegate

        // Route polyline renderer — cyan color matching design system
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(red: 0, green: 0.83, blue: 1.0, alpha: 0.9)
                renderer.lineWidth = 6
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // Destination annotation view
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard !(annotation is MKUserLocation) else { return nil }
            let id = "destination"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            if let marker = view as? MKMarkerAnnotationView {
                marker.markerTintColor = UIColor(red: 1, green: 0.24, blue: 0.44, alpha: 1)
                marker.glyphImage = UIImage(systemName: "flag.fill")
                marker.canShowCallout = true
            }
            return view
        }

        // Detect when user starts panning — stop auto-centering
        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if !animated {
                userInteracting = true
            }
        }

        // After user stops interacting, re-enable tracking after 5s
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if userInteracting {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak mapView] in
                    self?.userInteracting = false
                    mapView?.setUserTrackingMode(.followWithHeading, animated: true)
                }
            }
        }
    }
}

// MARK: - Search Bar

struct SearchBarWithResults: View {
    @EnvironmentObject var vm: DriveViewModel
    @State private var query: String = ""
    @State private var showResults: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search input row
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color(hex: "#00D4FF"))
                    .font(.system(size: 16, weight: .medium))

                TextField("", text: $query, prompt:
                    Text("Search destination...")
                        .foregroundColor(Color(hex: "#8888AA"))
                )
                .foregroundColor(.white)
                .font(.system(size: 16))
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { triggerSearch() }
                .onChange(of: query) { newValue in
                    if newValue.isEmpty {
                        vm.searchResults = []
                        showResults = false
                    }
                }

                if !query.isEmpty {
                    Button(action: triggerSearch) {
                        Text("Go")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color(hex: "#00D4FF"))
                            .clipShape(Capsule())
                    }

                    Button(action: clearSearch) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(hex: "#8888AA"))
                            .font(.system(size: 16))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(hex: "#0F1022").opacity(0.95))
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
            )

            // Results dropdown
            if showResults && !vm.searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(vm.searchResults.indices, id: \.self) { i in
                        let item = vm.searchResults[i]
                        Button(action: {
                            selectDestination(item)
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(Color(hex: "#FF3D71"))
                                    .font(.system(size: 18))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Unknown")
                                        .foregroundColor(.white)
                                        .font(.system(size: 14, weight: .medium))
                                        .lineLimit(1)
                                    if let addr = item.placemark.title {
                                        Text(addr)
                                            .foregroundColor(Color(hex: "#8888AA"))
                                            .font(.system(size: 12))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }

                        if i < vm.searchResults.count - 1 {
                            Divider()
                                .background(Color(hex: "#1A1B2E"))
                                .padding(.leading, 44)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: "#0F1022").opacity(0.97))
                        .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 8)
                )
                .padding(.top, 4)
            }

            // Loading indicator
            if vm.isSearching {
                HStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "#00D4FF")))
                        .scaleEffect(0.8)
                    Text("Searching...")
                        .foregroundColor(Color(hex: "#8888AA"))
                        .font(.system(size: 13))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: "#0F1022").opacity(0.97))
                )
                .padding(.top, 4)
            }
        }
        .onChange(of: vm.searchResults) { results in
            showResults = !results.isEmpty
        }
    }

    private func triggerSearch() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { await vm.searchDestination(query: query) }
    }

    private func clearSearch() {
        query = ""
        vm.searchResults = []
        showResults = false
        focused = false
        vm.endNavigation()
    }

    private func selectDestination(_ item: MKMapItem) {
        focused = false
        showResults = false
        query = item.name ?? ""
        Task { await vm.startNavigation(to: item) }
    }
}

// MARK: - Speed HUD Pill

struct SpeedHUDPill: View {
    @EnvironmentObject var vm: DriveViewModel
    @Environment(\.horizontalSizeClass) var sizeClass

    // Pulse animation for overspeed
    @State private var pulsing = false

    private var isLandscape: Bool { sizeClass == .regular }

    var body: some View {
        HStack(spacing: isLandscape ? 12 : 16) {

            // ── Speed Limit Badge
            SpeedLimitBadge(limit: vm.limit, source: vm.speedLimitSource)
                .frame(width: isLandscape ? 44 : 56, height: isLandscape ? 44 : 56)

            Divider()
                .frame(height: isLandscape ? 32 : 44)
                .background(Color(hex: "#1A1B2E"))

            // ── Current Speed
            VStack(spacing: 2) {
                if vm.isRecording {
                    RecordingBadge(duration: vm.sessionDuration)
                }
                Text(String(format: "%.0f", vm.speed))
                    .font(.system(size: isLandscape ? 36 : 52,
                                  weight: .black,
                                  design: .rounded))
                    .foregroundColor(speedColor)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("MPH")
                    .font(.system(size: isLandscape ? 10 : 12,
                                  weight: .semibold))
                    .foregroundColor(Color(hex: "#8888AA"))
                    .kerning(2)
            }
            .frame(minWidth: isLandscape ? 70 : 90)

            Divider()
                .frame(height: isLandscape ? 32 : 44)
                .background(Color(hex: "#1A1B2E"))

            // ── Status indicator dot
            Circle()
                .fill(statusColor)
                .frame(width: 14, height: 14)
                .scaleEffect(pulsing && vm.status == .over ? 1.35 : 1.0)
                .animation(
                    vm.status == .over
                        ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )
                .onAppear { pulsing = true }

            Spacer()

            // ── Navigation status (when active)
            if vm.isNavigating {
                NavigationInfoMini()
                    .environmentObject(vm)
            }

            // ── Start / Stop button
            Button(action: {
                if vm.isRecording { vm.endSession() }
                else { vm.startSession() }
            }) {
                Text(vm.isRecording ? "STOP" : "START")
                    .font(.system(size: isLandscape ? 11 : 13, weight: .bold))
                    .foregroundColor(vm.isRecording ? .white : .black)
                    .frame(width: 72, height: 40)
                    .background(
                        Capsule()
                            .fill(vm.isRecording
                                  ? Color(hex: "#FF3D71")
                                  : Color(hex: "#00D4FF"))
                    )
            }
        }
        .padding(.horizontal, isLandscape ? 14 : 18)
        .padding(.vertical, isLandscape ? 10 : 14)
        .background(
            Capsule()
                .fill(Color(hex: "#0F1022").opacity(0.96))
                .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 6)
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    vm.status == .over
                        ? Color(hex: "#FF3D71").opacity(0.6)
                        : Color(hex: "#1A1B2E"),
                    lineWidth: 1
                )
        )
    }

    private var speedColor: Color {
        switch vm.status {
        case .safe: return .white
        case .warning: return Color(hex: "#FFB800")
        case .over: return Color(hex: "#FF3D71")
        }
    }

    private var statusColor: Color {
        switch vm.status {
        case .safe: return Color(hex: "#00FF9D")
        case .warning: return Color(hex: "#FFB800")
        case .over: return Color(hex: "#FF3D71")
        }
    }
}

// MARK: - Speed Limit Badge

struct SpeedLimitBadge: View {
    let limit: Int
    let source: String

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // Outer white circle with red border
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.red, lineWidth: 3))

                VStack(spacing: 0) {
                    Spacer(minLength: 4)
                    Text(limit > 0 ? "\(limit)" : "--")
                        .font(.system(size: limit >= 100 ? 13 : 17,
                                      weight: .black))
                        .foregroundColor(.black)
                    // Red MPH band at bottom
                    ZStack {
                        Rectangle()
                            .fill(Color.red)
                            .frame(height: 14)
                            .clipShape(
                                .rect(
                                    bottomLeadingRadius: 100,
                                    bottomTrailingRadius: 100
                                )
                            )
                        Text("MPH")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .frame(width: 52, height: 52)

            // Data source label
            Text(sourceLabel)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(sourceColor)
                .kerning(0.5)
        }
    }

    private var sourceLabel: String {
        if source.contains("OpenStreetMap") { return "OSM" }
        if source.contains("Estimated") { return "EST" }
        return "···"
    }

    private var sourceColor: Color {
        if source.contains("OpenStreetMap") { return Color(hex: "#00D4FF") }
        return Color(hex: "#8888AA")
    }
}

// MARK: - Recording Badge

struct RecordingBadge: View {
    let duration: TimeInterval
    @State private var blinking = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color(hex: "#FF3D71"))
                .frame(width: 6, height: 6)
                .opacity(blinking ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: blinking)
                .onAppear { blinking = true }
            Text("REC \(formattedDuration)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: "#FF3D71"))
        }
    }

    private var formattedDuration: String {
        let h = Int(duration) / 3600
        let m = (Int(duration) % 3600) / 60
        let s = Int(duration) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Navigation Info (mini, shown in pill when navigating)

struct NavigationInfoMini: View {
    @EnvironmentObject var vm: DriveViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(vm.nextManeuverInstruction.isEmpty
                 ? "Navigating" : vm.nextManeuverInstruction)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            if let eta = vm.eta {
                Text("ETA \(eta, style: .time)")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#8888AA"))
            }
        }
        .frame(maxWidth: 120)
    }
}

// MARK: - Color Extension (hex support)
// Note: Color(hex:) must already be defined in Color+Theme.swift
// If not, add it there. Do not duplicate it here.