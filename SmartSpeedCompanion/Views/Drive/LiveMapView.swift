import SwiftUI
import MapKit

public struct LiveMapView: UIViewRepresentable {
    @EnvironmentObject var viewModel: DriveViewModel
    
    public init() {}
    
    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Use system appearance only when the chosen MapStyleChoice is the dark
        // .mutedDark default; lighter styles should respect the user's iOS theme.
        let style = viewModel.mapStyle
        map.overrideUserInterfaceStyle = (style == .mutedDark) ? .dark : .unspecified

        // Apply the user's chosen MapStyleChoice. Each branch maps to a native
        // MKMapConfiguration subclass — 100% free, no token required.
        applyMapStyle(style, to: map)

        #if DEBUG || DEVELOPER_BUILD
        if viewModel.locationManager.isMockMode {
            map.showsUserLocation = false
        } else {
            map.showsUserLocation = true
        }
        #else
        map.showsUserLocation = true
        #endif

        map.showsCompass = false // We'll surface a native MKCompassButton instead.
        map.showsScale = false   // We'll surface MKScaleView (preserved).

        // Native controls setup — scale + compass + tracking + pitch-toggle.
        setupNativeControls(for: map)

        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true

        // Surface the system pitch toggle. MKPitchToggle does not exist
        // in iOS MapKit (the SwiftUI analog is `MapPitchToggle(view:)`,
        // not an MK-prefixed class), so the system-rendered button is the
        // on-device native option — it theming-picks-up dark mode itself.
        if #available(iOS 16.0, *) {
            map.pitchButtonVisibility = .visible
        }

        // MKUserTrackingButton is added as an explicit subview in
        // setupNativeControls(for:) — we deliberately do NOT also set
        // `map.showsUserTrackingButton = true` here, otherwise the system
        // would add a duplicate at its default location.

        // Use native tracking with heading for best centering reliability.
        map.userTrackingMode = .followWithHeading

        // Add gesture detection for manual mode.
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleManualInteraction(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleManualInteraction(_:)))
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)

        // Honor the persisted POI toggle from Settings — on by default for
        // .gasStation / .parking / .hospital / .police / .restaurant / .cafe.
        applyPOIFilter(viewModel.showApplePOIs, to: map)

        return map
    }

    /// Swap the active MKMapConfiguration to match the user's MapStyleChoice.
    /// Called on `makeUIView` and whenever `viewModel.mapStyleRaw` changes.
    private func applyMapStyle(_ style: DriveViewModel.MapStyleChoice, to map: MKMapView) {
        if #available(iOS 17.0, *) {
            switch style {
            case .mutedDark:
                let cfg = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
                cfg.showsTraffic = true
                map.preferredConfiguration = cfg
            case .standard:
                let cfg = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
                cfg.showsTraffic = true
                map.preferredConfiguration = cfg
            case .satellite:
                let cfg = MKImageryMapConfiguration(elevationStyle: .realistic)
                map.preferredConfiguration = cfg
            case .hybridFlyover:
                let cfg = MKHybridMapConfiguration(elevationStyle: .realistic)
                map.preferredConfiguration = cfg
            }
        } else if #available(iOS 16.0, *) {
            // iOS 16 fallback (we deploy 18+ but keep guard for safety).
            let cfg = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            cfg.showsTraffic = true
            map.preferredConfiguration = cfg
        } else {
            map.mapType = (style == .satellite || style == .hybridFlyover) ? .satellite : .mutedStandard
        }
    }

    /// Toggles Apple's native POI glyphs (gas / food / hospital / parking).
    /// Empty include-list = nothing shown (the right "off" behavior).
    private func applyPOIFilter(_ show: Bool, to map: MKMapView) {
        if show {
            map.pointOfInterestFilter = MKPointOfInterestFilter(including: [
                .gasStation, .parking, .hospital, .police, .restaurant, .cafe, .pharmacy, .atm
            ])
        } else {
            // MKPointOfInterestFilter(including: []) hides all POI glyphs.
            // Previously we used excludingAll:[] which actually shows ALL 50+
            // categories — a regression flagged by code review.
            map.pointOfInterestFilter = MKPointOfInterestFilter(including: [])
        }
    }

    private func setupNativeControls(for map: MKMapView) {
        // MARK: - Native MKScaleView
        // Apple's own scale legend that updates automatically with the camera.
        let scale = MKScaleView(mapView: map)
        scale.scaleVisibility = .adaptive
        scale.legendAlignment = .leading
        scale.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(scale)

        // Bottom-trailing stack: pitch toggle above compass above tracking
        // button. All three are free on-device controls (no API/token).
        guard #available(iOS 17.0, *) else {
            NSLayoutConstraint.activate([
                scale.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 10),
                scale.leadingAnchor.constraint(equalTo: map.leadingAnchor, constant: 16)
            ])
            return
        }

        // MKCompassButton — appears only when the user has rotated the map
        // away from true north so we don't clutter the chrome otherwise.
        let compass = MKCompassButton(mapView: map)
        compass.compassVisibility = .adaptive
        compass.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(compass)

        // MKUserTrackingButton — explicit recenter. The system one
        // (`map.showsUserTrackingButton = true`) is disabled below so the
        // user only sees this single pinned instance.
        let trackingButton = MKUserTrackingButton(mapView: map)
        trackingButton.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(trackingButton)

        NSLayoutConstraint.activate([
            scale.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 10),
            scale.leadingAnchor.constraint(equalTo: map.leadingAnchor, constant: 16),

            compass.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -16),
            compass.bottomAnchor.constraint(equalTo: map.safeAreaLayoutGuide.bottomAnchor, constant: -180),

            trackingButton.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -16),
            trackingButton.bottomAnchor.constraint(equalTo: compass.topAnchor, constant: -10)
        ])
    }
    
    public func updateUIView(_ uiView: MKMapView, context: Context) {
        // Swap in the map style / POI filter ASAP after the underlying UserDefaults
        // value mutates from the Settings screen. Comparing via a coordinator
        // cache avoids rebuilding the MKMapConfiguration (and the camera
        // animation that comes with it) on every UIViewRepresentable invalidate.
        let currentStyle = viewModel.mapStyle
        if context.coordinator.lastAppliedMapStyle != currentStyle {
            applyMapStyle(currentStyle, to: uiView)
            context.coordinator.lastAppliedMapStyle = currentStyle
        }
        if context.coordinator.lastAppliedShowPOIs != viewModel.showApplePOIs {
            applyPOIFilter(viewModel.showApplePOIs, to: uiView)
            context.coordinator.lastAppliedShowPOIs = viewModel.showApplePOIs
        }

        // Limit camera updates during search to prevent unwanted "jumping"
        // while the keyboard is up.
        if viewModel.isSearching || viewModel.isSearchingLocally {
            // We still want to update overlays (status line), but we skip camera changes.
            context.coordinator.updateOverlaysIfNeeded(uiView, viewModel: viewModel)
            return
        }

        // If user has manually detached, just release any zoom restriction and stop
        if viewModel.isMapDetached {
            if uiView.userTrackingMode != .none {
                uiView.userTrackingMode = .none
            }
            return
        }
        
        // Re-engage native tracking if it was released
        if uiView.userTrackingMode == .none {
            #if DEBUG || DEVELOPER_BUILD
            if !viewModel.locationManager.isMockMode {
                uiView.setUserTrackingMode(.followWithHeading, animated: true)
            }
            #else
            uiView.setUserTrackingMode(.followWithHeading, animated: true)
            #endif
        }
        
        #if DEBUG || DEVELOPER_BUILD
        if viewModel.locationManager.isMockMode {
            // Update Simulated Car position and camera manually
            context.coordinator.updateSimulatedCar(uiView, viewModel: viewModel)
        }
        #endif
        
        // Adjust camera altitude (pitch + zoom) without breaking tracking mode
        updateSmartAltitude(uiView, context: context)
        
        // Update overlays only when necessary (not every single frame)
        context.coordinator.updateOverlaysIfNeeded(uiView, viewModel: viewModel)
    }
    
    // MARK: - Smart Altitude Adjustment
    // We ONLY change altitude and pitch, not the center coordinate.
    // Native followWithHeading handles re-centering perfectly.
    private func updateSmartAltitude(_ uiView: MKMapView, context: Context) {
        let speed = viewModel.speed
        let limit = viewModel.limit
        let distanceToTurn = viewModel.distanceToNextTurn
        let isNavigating = viewModel.isNavigating
        let isRecording = viewModel.isRecording
        
        let currentAltitude = uiView.camera.centerCoordinateDistance
        let currentPitch = Double(uiView.camera.pitch)
        
        // ─── STATIONARY GUARD ──────────────────────────────────────────────────
        // If the device is not moving, never change the zoom level.
        if speed < 3.0 { // Approx 6 mph
            return
        }
        
        var targetAltitude: Double = 1000
        var targetPitch: Double = 0
        var zoomReason = "unk"

        // 3D flyover mode (user toggle) — only when navigating and on a long
        // straight highway stretch so we don't disorient the driver in cities.
        if viewModel.threeDFlyoverEnabled && isNavigating && distanceToTurn > 4000 && speed > 50 {
            targetAltitude = max(targetAltitude, 3500)
            targetPitch = 55
            zoomReason += "+flyover"
        }
        
        // ─── LOGICAL ZOOM STATE (Hysteresis-ready) ──────────────────────────────
        // We use speed + limit to determine a "Base Level" then apply overrides.
        if isNavigating {
            targetPitch = 45
            
            // Determine base altitude based on speed AND limit for stability
            // If the road is a high-speed road (limit > 55), we stay zoomed out even if slowing down slightly.
            if limit > 55 || speed > 55 {
                targetAltitude = 1800
                zoomReason = "highway"
            } else if limit > 35 || speed > 35 {
                targetAltitude = 1200
                zoomReason = "suburban"
            } else if speed < 18 {
                targetAltitude = 500
                zoomReason = "city-slow"
            } else {
                targetAltitude = 800
                zoomReason = "city"
            }
            
            // ─── OVERRIDES ──────────────────────────────────────────────────────
            
            // Turn proximity override (OVERRIDES speed-based zoom).
            // TestFlight v2.1.4: zoom in once turn is within 1000 ft (~315 m,
            // with overlap to avoid threshold jitter) and stay until made.
            if distanceToTurn < 125 {
                targetAltitude = 380
                zoomReason = "turn-near"
            } else if distanceToTurn < 315 {
                // minTurnAlt = 400 so city base (800) drops 400m > 300m diff,
                // ensuring the stability-engine actually fires setCamera().
                let minTurnAlt = 400.0
                targetAltitude = min(targetAltitude, minTurnAlt)
                zoomReason += "+turn-appr-1kft"
            }
            
            // Destination approach (closer = lower and more top-down)
            if let dest = viewModel.destination {
                let destLoc = dest.placemark.location ?? CLLocation()
                let userLoc = uiView.userLocation.location ?? viewModel.locationManager.latestLocation
                if let userLoc = userLoc {
                    let distToDest = userLoc.distance(from: destLoc)
                    if distToDest < 150 {
                        targetAltitude = 280
                        targetPitch = 30
                        zoomReason = "arrival"
                    } else if distToDest < 600 {
                        targetAltitude = min(targetAltitude, 450)
                        targetPitch = 35
                        zoomReason += "+dest-near"
                    }
                }
            }
            
            // Interchange/Ramp override (Needs more context of path)
            let instruction = viewModel.nextManeuverInstruction.lowercased()
            if instruction.contains("exit") || instruction.contains("merge") ||
               instruction.contains("ramp") || instruction.contains("fork") {
                // Zoom out slightly on ramps to see context
                targetAltitude = max(targetAltitude, 800)
                zoomReason += "+ramp"
            }
            
            // Long straight (zoom out to see more road ahead)
            if distanceToTurn > 3000 && speed > 50 {
                targetAltitude = max(targetAltitude, 2500)
                zoomReason += "+straight"
            }
            
        } else if isRecording {
            targetPitch = 30
            // Simplified levels for free-driving (recording)
            if speed > 55 {
                targetAltitude = 2200; zoomReason = "rec-fast"
            } else if speed > 30 {
                targetAltitude = 1400; zoomReason = "rec-mid"
            } else {
                targetAltitude = 850; zoomReason = "rec-slow"
            }
        } else {
            targetPitch = 0
            targetAltitude = 2000
            zoomReason = "idle"
        }
        
        // ─── STABILITY ENGINE (Threshold + Cooldown) ─────────────────────────────
        // We use a MUCH tighter altitude threshold (300m instead of 800m)
        // to make the steps actually work, but a LONGER cooldown (4s)
        // to ensure it doesn't feel frantic.
        
        let altDiff = abs(currentAltitude - targetAltitude)
        let pitchDiff = abs(currentPitch - targetPitch)
        let timeSinceLastChange = Date().timeIntervalSince(context.coordinator.lastCameraChangeTime)
        
        // Special case: If we are very close to a turn (<120m), we ignore the cooldown 
        // to ensure we zoom in for the turn exactly when needed.
        let isCriticalZoom = (distanceToTurn < 120 && isNavigating && targetAltitude < 400)
        let cooldown = isCriticalZoom ? 1.0 : context.coordinator.cameraChangeCooldown
        
        if (altDiff > 300 || pitchDiff > 12) && timeSinceLastChange >= cooldown {
            DebugLogger.shared.log("CAM [\(zoomReason)]: \(Int(currentAltitude))m -> \(Int(targetAltitude))m | spd=\(Int(speed))")
            context.coordinator.lastCameraChangeTime = Date()
            
            let newCamera = uiView.camera.copy() as! MKMapCamera
            newCamera.centerCoordinateDistance = targetAltitude
            newCamera.pitch = CGFloat(targetPitch)
            uiView.setCamera(newCamera, animated: true)
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: LiveMapView
        private var interactionTimer: Timer?
        // Minimum seconds between camera altitude/pitch adjustments to suppress jitter
        // Variables must be internal (not private) so the View can access them
        var lastCameraChangeTime: Date = .distantPast
        let cameraChangeCooldown: TimeInterval = 4.0

        // Cache the last-applied map style / POI filter so we don't rebuild
        // the MKMapConfiguration (and trigger a fresh camera animation) on
        // every UIViewRepresentable invalidate.
        var lastAppliedMapStyle: DriveViewModel.MapStyleChoice? = nil
        var lastAppliedShowPOIs: Bool? = nil
        // Maneuver annotation we own — ref so we don't churn annotations on
        // every GPS ping.
        private var maneuverAnnotation: ManeuverAnnotation? = nil

        // Overlay state tracking to avoid redundant remove/add cycles
        private var lastRoutePolylineCount: Int = 0
        private var lastHistoryCounts: (safeCount: Int, overCount: Int) = (0, 0)
        private var lastIsNavigating: Bool = false
        private var lastRouteDistance: Double = 0
        private var lastSessionReadingCount: Int = 0
        private var hasAutoFramedRoute: Bool = false
        
        #if DEBUG || DEVELOPER_BUILD
        private var simulatedCarAnnotation: MKPointAnnotation?
        #endif
        
        init(_ parent: LiveMapView) {
            self.parent = parent
        }
        
        @objc func handleManualInteraction(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed {
                startManualMode(gesture.view as? MKMapView)
            }
        }
        
        public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
        
        public func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // No-op here. We only detach on actual gesture recognizers to avoid
            // detaching when the system updates the altitude or follows the user.
        }
        
        private func startManualMode(_ mapView: MKMapView?) {
            // First, kill any existing resume timer
            interactionTimer?.invalidate()
            
            if !parent.viewModel.isMapDetached {
                parent.viewModel.isMapDetached = true
                mapView?.userTrackingMode = .none
                DebugLogger.shared.log("MAP DETACHED: Manual Control")
            }
            
            // Auto-resume after 10 seconds of inactivity (longer to be safe)
            interactionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.parent.viewModel.isMapDetached = false
                    DebugLogger.shared.log("MAP ATTACHED: Tracking Resumed")
                }
            }
        }
        
        #if DEBUG || DEVELOPER_BUILD
        // MARK: - Simulation Management
        func updateSimulatedCar(_ mapView: MKMapView, viewModel: DriveViewModel) {
            guard let mockLocation = viewModel.locationManager.latestLocation else { return }
            
            // Rebuild annotation if missing
            if simulatedCarAnnotation == nil {
                let ann = MKPointAnnotation()
                ann.title = "SIMULATED_CAR"
                mapView.addAnnotation(ann)
                simulatedCarAnnotation = ann
            }
            
            // Update coordinate
            simulatedCarAnnotation?.coordinate = mockLocation.coordinate
            
            // Sync map showsUserLocation state
            if mapView.showsUserLocation != false {
                mapView.showsUserLocation = false
            }
            
            // If following, re-center map manually
            if !viewModel.isMapDetached {
                mapView.setCenter(mockLocation.coordinate, animated: true)
            }
        }
        #endif
        
        // MARK: - Smart Overlay Management
        // Only rebuild overlays when the underlying data actually changes.
        // This was the primary cause of 0.5 fps — removing and re-adding overlays every frame.
        func updateOverlaysIfNeeded(_ mapView: MKMapView, viewModel: DriveViewModel) {
            let vm = viewModel
            let currentRouteDistance = vm.currentRoute?.distance ?? 0
            let currentReadingCount = vm.sessionRecorder.currentSession?.readings.count ?? 0
            let isNavigating = vm.isNavigating
            
            let routeChanged = isNavigating != lastIsNavigating || abs(currentRouteDistance - lastRouteDistance) > 1.0
            // Throttling: only rebuild history every 5 points to save battery
            let historyChanged = currentReadingCount >= lastHistoryCounts.safeCount + lastHistoryCounts.overCount + 5
            
            guard routeChanged || historyChanged || (isNavigating && lastRouteDistance == 0) else { return }
            
            // Perform the overlay rebuild only when data changed
            rebuildOverlays(mapView, viewModel: vm)
            
            // Update tracking state
            lastIsNavigating = isNavigating
            lastRouteDistance = currentRouteDistance
            let readings = vm.sessionRecorder.currentSession?.readings ?? []
            let safeCount = readings.filter { !$0.overLimit }.count
            let overCount = readings.filter { $0.overLimit }.count
            lastHistoryCounts = (safeCount, overCount)
        }
        
        private func rebuildOverlays(_ mapView: MKMapView, viewModel: DriveViewModel) {
            // Remove all overlays and non-user annotations
            mapView.removeOverlays(mapView.overlays)
            mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })

            // Route polyline + destination
            if viewModel.isNavigating, let route = viewModel.currentRoute {
                // Glow layer (drawn first, sits BELOW the route line)
                let glowLine = GlowPolyline(points: route.polyline.points(), count: route.polyline.pointCount)
                glowLine.glowColor = UIColor(DesignSystem.cyan)
                mapView.addOverlay(glowLine, level: .aboveRoads)

                // Main route polyline. Use a gradient stroke when the user
                // has opted in (iOS 17+ MKGradientPolylineRenderer) so the
                // line has the colored gradient look Apple Maps ships by default.
                let polyline = NavPolyline(points: route.polyline.points(), count: route.polyline.pointCount)
                polyline.statusColor = UIColor(DesignSystem.cyan)
                polyline.isRouteOverlay = true
                polyline.useGradient = viewModel.gradientRouteEnabled
                mapView.addOverlay(polyline, level: .aboveRoads)

                if let dest = viewModel.destination {
                    let destinationAnnotation = MKPointAnnotation()
                    destinationAnnotation.coordinate = dest.placemark.coordinate
                    destinationAnnotation.title = dest.name
                    mapView.addAnnotation(destinationAnnotation)
                }

                // Speed-camera annotations get the native MapKit clustering
                // treatment so a state full of cameras collapses into a single
                // numeric badge when zoomed out (Apple Maps behavior). The
                // 5 km radius matches SpeedCameraService.getNearbyCameras's
                // default — wider dumps the entire AZ-511 catalog onto the map.
                if !SpeedCameraService.shared.cameras.isEmpty {
                    let nearby = SpeedCameraService.shared.getNearbyCameras(
                        to: viewModel.locationManager.latestLocation ?? CLLocation()
                    )
                    for camera in nearby.prefix(60) {
                        let ann = SpeedCameraAnnotation(camera: camera)
                        mapView.addAnnotation(ann)
                    }
                }

                // MKMapRect auto-fit: when a fresh route appears and we
                // haven't already framed it, animate to a rect that contains
                // the entire polyline plus the current location so the user
                // sees the full trip before zoom-in kicks in.
                if !hasAutoFramedRoute {
                    var rect = route.polyline.boundingMapRect
                    if let userLoc = viewModel.locationManager.latestLocation {
                        let userRect = MKMapRect(
                            x: MKMapPoint(userLoc.coordinate).x - 1_000,
                            y: MKMapPoint(userLoc.coordinate).y - 1_000,
                            width: 2_000,
                            height: 2_000
                        )
                        rect = rect.union(userRect)
                    }
                    mapView.setVisibleMapRect(
                        rect,
                        edgePadding: UIEdgeInsets(top: 80, left: 60, bottom: 200, right: 60),
                        animated: true
                    )
                    hasAutoFramedRoute = true
                }
            } else {
                // Drop the auto-fit latch when navigation ends so the next
                // navigation re-frames the polyline.
                hasAutoFramedRoute = false
            }

            // Maneuver annotation — a large arrow dropped at the upcoming
            // turn point so the driver sees the exact spot even with the HUD
            // card occluded (e.g. when panning the map manually).
            if let coord = viewModel.nextManeuverCoordinate {
                if let existing = maneuverAnnotation {
                    // glyph is a plain Swift var (no KVO), so MapKit doesn't
                    // re-call viewFor: when only the arrow type changes
                    // mid-route. Push the new glyphImage directly to the
                    // live view so the user sees "left" -> "right" flips
                    // without panning first.
                    let glyphChanged = existing.glyph != viewModel.nextManeuverImageName
                    existing.coordinate = coord
                    existing.glyph = viewModel.nextManeuverImageName
                    if glyphChanged, let view = mapView.view(for: existing) as? MKMarkerAnnotationView {
                        view.glyphImage = UIImage(systemName: viewModel.nextManeuverImageName)
                            ?? UIImage(systemName: "arrow.up")
                        view.glyphTintColor = .white
                    }
                } else {
                    let ann = ManeuverAnnotation(
                        coordinate: coord,
                        glyph: viewModel.nextManeuverImageName
                    )
                    mapView.addAnnotation(ann)
                    maneuverAnnotation = ann
                }
            } else if let existing = maneuverAnnotation {
                mapView.removeAnnotation(existing)
                maneuverAnnotation = nil
            }

            // History line (color-coded by speed status)
            buildHistoryOverlays(mapView, viewModel: viewModel)
        }
        
        private func buildHistoryOverlays(_ mapView: MKMapView, viewModel: DriveViewModel) {
            guard let session = viewModel.sessionRecorder.currentSession, !session.readings.isEmpty else { return }
            
            var safeCoords: [CLLocationCoordinate2D] = []
            var overCoords: [CLLocationCoordinate2D] = []
            
            for reading in session.readings {
                let coord = CLLocationCoordinate2D(latitude: reading.latitude, longitude: reading.longitude)
                if reading.overLimit {
                    if !safeCoords.isEmpty {
                        let polyline = NavPolyline(coordinates: safeCoords, count: safeCoords.count)
                        polyline.statusColor = UIColor(white: 0.5, alpha: 0.5) // Light gray for safe path
                        mapView.addOverlay(polyline, level: .aboveRoads)
                        safeCoords.removeAll()
                    }
                    overCoords.append(coord)
                } else {
                    if !overCoords.isEmpty {
                        let polyline = NavPolyline(coordinates: overCoords, count: overCoords.count)
                        polyline.statusColor = UIColor(DesignSystem.alertRed)
                        mapView.addOverlay(polyline, level: .aboveRoads)
                        overCoords.removeAll()
                    }
                    safeCoords.append(coord)
                }
            }
            if !safeCoords.isEmpty {
                let polyline = NavPolyline(coordinates: safeCoords, count: safeCoords.count)
                polyline.statusColor = UIColor(white: 0.5, alpha: 0.5) // Light gray for safe path
                mapView.addOverlay(polyline, level: .aboveRoads)
            }
            if !overCoords.isEmpty {
                let polyline = NavPolyline(coordinates: overCoords, count: overCoords.count)
                polyline.statusColor = UIColor(DesignSystem.alertRed)
                mapView.addOverlay(polyline, level: .aboveRoads)
            }
        }
        
        // MARK: - MKMapViewDelegate

        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? NavPolyline {
                // GRADIENT ROUTE: only the ROUTE polyline upgrades to
                // MKGradientPolylineRenderer. History polylines get the flat
                // MKPolylineRenderer below (the previous behavior) since
                // passing identical cyan-cyan stops renders as a flat color.
                if #available(iOS 17.0, *), polyline.useGradient, polyline.isRouteOverlay {
                    let renderer = MKGradientPolylineRenderer(polyline: polyline)
                    let colors: [UIColor] = [
                        UIColor(DesignSystem.cyan),
                        UIColor(DesignSystem.neonGreen)
                    ]
                    let stops: [CGFloat] = [0.0, 1.0]
                    renderer.setColors(colors, locations: stops.map { NSNumber(value: Double($0)) })
                    renderer.lineWidth = 7.0
                    renderer.lineCap = .round
                    renderer.lineJoin = .round
                    return renderer
                }

                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.statusColor
                renderer.lineWidth = polyline.isRouteOverlay ? 7.0 : 5.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                if polyline.isRouteOverlay {
                    renderer.strokeColor = polyline.statusColor.withAlphaComponent(0.85)
                }
                return renderer
            }

            // Shadow/glow polyline rendered underneath the main route
            if let polyline = overlay as? GlowPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.glowColor.withAlphaComponent(0.3)
                renderer.lineWidth = 14.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            #if DEBUG || DEVELOPER_BUILD
            if annotation.title == "SIMULATED_CAR" {
                let id = "SimCar"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKUserLocationView
                if view == nil {
                    view = MKUserLocationView(annotation: annotation, reuseIdentifier: id)
                } else {
                    view?.annotation = annotation
                }
                return view
            }
            #endif

            // Native clustering identifier for all speed cameras. MapKit
            // automatically collapses them into a single numeric badge when
            // zoomed out (Apple Maps behavior) — this is the user's "pinch
            // out to see clusters" experience, free.
            if annotation is SpeedCameraAnnotation {
                let id = SpeedCameraAnnotation.clusterIdentifier
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView
                if view == nil {
                    view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                    view?.markerTintColor = UIColor(DesignSystem.alertRed)
                    view?.glyphImage = UIImage(systemName: "camera.fill")
                    view?.canShowCallout = true
                    view?.clusteringIdentifier = id
                } else {
                    view?.annotation = annotation
                    view?.clusteringIdentifier = id
                }
                return view
            }

            // Maneuver annotation: rendered with a giant arrow glyph inside
            // a glassy disc so the upcoming turn is impossible to miss.
            // NOTE: glyphImage must be re-set on EVERY viewFor call — the
            // dequeued view's glyphImage is sticky across reuse, so without
            // setting it the user would see the old arrow after the maneuver
            // type changes mid-route.
            if let maneuver = annotation as? ManeuverAnnotation {
                let id = ManeuverAnnotation.reuseIdentifier
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    as? MKMarkerAnnotationView
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.canShowCallout = false
                view.isEnabled = true
                view.centerOffset = CGPoint(x: 0, y: -8)
                view.markerTintColor = UIColor(DesignSystem.alertRed)
                view.glyphImage = UIImage(systemName: maneuver.glyph)
                    ?? UIImage(systemName: "arrow.up")
                view.glyphTintColor = .white
                view.displayPriority = .required
                return view
            }

            let identifier = "Destination"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.canShowCallout = true
                view?.markerTintColor = UIColor(DesignSystem.cyan)
                view?.glyphImage = UIImage(systemName: "mappin")
            } else {
                view?.annotation = annotation
            }
            return view
        }
        
        public func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // If the system changed tracking mode (e.g. user rotated device), log it
            DebugLogger.shared.log("Tracking mode changed to: \(mode.rawValue)")
        }
    }
}

class NavPolyline: MKPolyline {
    var statusColor: UIColor = .systemBlue
    var isRouteOverlay: Bool = false
    /// Drive from Settings. When true on iOS 17+, the renderer upgrades to
    /// MKGradientPolylineRenderer to give the polyline the colored gradient
    /// stroke Apple Maps ships by default.
    var useGradient: Bool = false
}

class GlowPolyline: MKPolyline {
    var glowColor: UIColor = .systemCyan
}

/// Marker annotation for the upcoming turn point. MKMarkerAnnotationView picks
/// up our SF Symbol `glyph` so the arrow type (left/right/U-turn/exit) mirrors
/// the HUD card without any duplicated drawing code.
final class ManeuverAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "ManeuverArrow"
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var glyph: String
    var title: String? = "Next turn"

    init(coordinate: CLLocationCoordinate2D, glyph: String) {
        self.coordinate = coordinate
        self.glyph = glyph
        super.init()
    }
}

/// Marker annotation for a Speed Camera. The view for this annotation sets
/// `clusteringIdentifier = SpeedCameraAnnotation.clusterIdentifier` so when
/// the user has 200+ cameras on screen, MapKit groups them into a single
/// numeric badge automatically — free native feature.
final class SpeedCameraAnnotation: NSObject, MKAnnotation {
    static let clusterIdentifier = "SpeedCamera"
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var camera: SpeedCamera

    init(camera: SpeedCamera) {
        self.camera = camera
        self.coordinate = CLLocationCoordinate2D(
            latitude: camera.latitude,
            longitude: camera.longitude
        )
        super.init()
    }
}