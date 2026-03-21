import SwiftUI
import MapKit

public struct LiveMapView: UIViewRepresentable {
    @EnvironmentObject var viewModel: DriveViewModel
    
    public init() {}
    
    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        
        // MODERN: Use MKStandardMapConfiguration instead of deprecated mapType
        // .realistic gives 3D buildings and terrain elevation
        // .muted keeps the dark, professional look without distracting colors
        if #available(iOS 16.0, *) {
            let config = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .muted)
            config.showsTraffic = true  // Show real-time traffic conditions
            map.preferredConfiguration = config
        } else {
            map.mapType = .mutedStandard
        }
        
        #if DEBUG || DEVELOPER_BUILD
        if viewModel.locationManager.isMockMode {
            map.showsUserLocation = false
        } else {
            map.showsUserLocation = true
        }
        #else
        map.showsUserLocation = true
        #endif
        
        map.showsCompass = false // We'll add custom components or use native elsewhere
        map.showsScale = false // We'll use MKScaleView
        
        // Native controls setup
        setupNativeControls(for: map)
        
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        
        // MODERN: Native pitch button (3D/2D toggle) — no custom UI needed
        if #available(iOS 16.0, *) {
            map.pitchButtonVisibility = .hidden
        }
        
        // MODERN: Native user tracking button — auto-shows re-center when lost
        if #available(iOS 17.0, *) {
            map.showsUserTrackingButton = true
        }
        
        // Use native tracking with heading for best centering reliability
        map.userTrackingMode = .followWithHeading
        
        // Add gesture detection for manual mode
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleManualInteraction(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleManualInteraction(_:)))
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)
        
        // Minimal POI filter for clean driving view
        let filter = MKPointOfInterestFilter(including: [
            .gasStation, .parking, .hospital, .police, .restaurant, .cafe
        ])
        map.pointOfInterestFilter = filter
        
        return map
    }

    private func setupNativeControls(for map: MKMapView) {
        // MKScaleView
        let scale = MKScaleView(mapView: map)
        scale.scaleVisibility = .adaptive
        scale.legendAlignment = .leading
        scale.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(scale)
        
        NSLayoutConstraint.activate([
            scale.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 10),
            scale.leadingAnchor.constraint(equalTo: map.leadingAnchor, constant: 16)
        ])
    }
    
    public func updateUIView(_ uiView: MKMapView, context: Context) {
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
            
            // Turn proximity override (OVERRIDES speed-based zoom)
            // We use a slight overlap to prevent bouncing exactly at the threshold
            if distanceToTurn < 125 {
                targetAltitude = 380
                zoomReason = "turn-near"
            } else if distanceToTurn < 400 {
                // Smoothly bring the altitude down as we approach the turn
                let minTurnAlt = 550.0
                targetAltitude = min(targetAltitude, minTurnAlt)
                zoomReason += "+turn-appr"
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
        
        // Overlay state tracking to avoid redundant remove/add cycles
        private var lastRoutePolylineCount: Int = 0
        private var lastHistoryCounts: (safeCount: Int, overCount: Int) = (0, 0)
        private var lastIsNavigating: Bool = false
        private var lastRouteDistance: Double = 0
        private var lastSessionReadingCount: Int = 0
        
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
                
                // Main route polyline
                let polyline = NavPolyline(points: route.polyline.points(), count: route.polyline.pointCount)
                polyline.statusColor = UIColor(DesignSystem.cyan)
                polyline.isRouteOverlay = true
                mapView.addOverlay(polyline, level: .aboveRoads)
                
                if let dest = viewModel.destination {
                    let annotation = MKPointAnnotation()
                    annotation.coordinate = dest.placemark.coordinate
                    annotation.title = dest.name
                    mapView.addAnnotation(annotation)
                }
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
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.statusColor
                renderer.lineWidth = polyline.isRouteOverlay ? 7.0 : 5.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                
                // Add a subtle glow effect for the route line
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
}

class GlowPolyline: MKPolyline {
    var glowColor: UIColor = .systemCyan
}