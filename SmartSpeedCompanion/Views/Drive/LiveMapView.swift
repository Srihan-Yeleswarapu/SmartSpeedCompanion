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
        
        map.showsUserLocation = true
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
            uiView.setUserTrackingMode(.followWithHeading, animated: true)
        }
        
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
        let distanceToTurn = viewModel.distanceToNextTurn
        let isNavigating = viewModel.isNavigating
        let isRecording = viewModel.isRecording
        
        let currentAltitude = uiView.camera.centerCoordinateDistance
        let currentPitch = Double(uiView.camera.pitch)
        
        // ─── STATIONARY GUARD ──────────────────────────────────────────────────
        // If the device is not moving, never change the zoom level.
        // This prevents the most common jitter: GPS noise causing speed to bounce
        // between 0 and a small value, triggering continuous zoom transitions.
        if speed < 2.0 {
            DebugLogger.shared.log("ZOOM SKIPPED [STATIONARY]: speed=\(String(format: "%.1f", speed)) mph, current=\(Int(currentAltitude))m")
            return
        }
        
        var targetAltitude: Double = 1000
        var targetPitch: Double = 0
        var zoomReason = "unknown"
        
        if isNavigating {
            targetPitch = 45
            
            switch speed {
            case 2..<5:
                targetAltitude = 350
                zoomReason = "nav-slow (<5mph)"
            case 5..<20:
                targetAltitude = 500
                zoomReason = "nav-city (5-20mph)"
            case 20..<40:
                targetAltitude = 900
                zoomReason = "nav-suburban (20-40mph)"
            case 40..<60:
                targetAltitude = 1400
                zoomReason = "nav-highway (40-60mph)"
            default:
                targetAltitude = 2000
                zoomReason = "nav-fast (>60mph)"
            }
            
            // Turn proximity override — zoom in near turns
            if distanceToTurn < 100 {
                targetAltitude = min(targetAltitude, 350)
                zoomReason += " +turnClose(<100m)"
            } else if distanceToTurn < 250 {
                targetAltitude = min(targetAltitude, 500)
                zoomReason += " +turnNear(<250m)"
            } else if distanceToTurn < 500 {
                targetAltitude = min(targetAltitude, 800)
                zoomReason += " +turnApproach(<500m)"
            }
            
            // Destination approach — only if userLoc is valid
            if let dest = viewModel.destination {
                let destLoc = dest.placemark.location ?? CLLocation()
                let userLoc = uiView.userLocation.location ?? viewModel.locationManager.latestLocation
                if let userLoc = userLoc {
                    let distToDest = userLoc.distance(from: destLoc)
                    if distToDest < 150 {
                        targetAltitude = 200
                        targetPitch = 30
                        zoomReason = "dest-arrival(<150m)"
                    } else if distToDest < 400 {
                        targetAltitude = min(targetAltitude, 350)
                        targetPitch = 35
                        zoomReason += " +destApproach(<400m)"
                    }
                }
            }
            
            // Highway / complex interchange — reveal surrounding area
            let instruction = viewModel.nextManeuverInstruction.lowercased()
            if instruction.contains("exit") || instruction.contains("merge") ||
               instruction.contains("ramp") || instruction.contains("fork") {
                targetAltitude = max(targetAltitude, 600)
                zoomReason += " +interchange"
            }
            
            // Long straight road at high speed — zoom out for situational awareness
            if distanceToTurn > 2000 && speed > 50 {
                targetAltitude = max(targetAltitude, 3000)
                zoomReason += " +longStraight"
            }
            
        } else if isRecording {
            targetPitch = 35
            if speed > 60 {
                targetAltitude = 3000; zoomReason = "rec-fast(>60mph)"
            } else if speed > 30 {
                targetAltitude = 1600; zoomReason = "rec-mid(30-60mph)"
            } else {
                targetAltitude = 900; zoomReason = "rec-slow(<30mph)"
            }
        } else {
            // Idle/Browsing overview — no pitch, moderate height
            targetPitch = 0
            targetAltitude = 2000
            zoomReason = "idle"
        }
        
        // ─── DEAD-BAND ─────────────────────────────────────────────────────────
        // Only animate if the change is large enough to be noticeable.
        // 200m altitude / 10° pitch threshold prevents micro-jitter from speed noise.
        let altDiff = abs(currentAltitude - targetAltitude)
        let pitchDiff = abs(currentPitch - targetPitch)
        
        if altDiff > 200 || pitchDiff > 10 {
            DebugLogger.shared.log("ZOOM CHANGE [\(zoomReason)]: \(Int(currentAltitude))->\(Int(targetAltitude))m | speed=\(String(format:"%.1f",speed)) dist=\(Int(distanceToTurn))m nav=\(isNavigating) rec=\(isRecording)")
            
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
        
        // Overlay state tracking to avoid redundant remove/add cycles
        private var lastRoutePolylineCount: Int = 0
        private var lastHistoryCounts: (safeCount: Int, overCount: Int) = (0, 0)
        private var lastIsNavigating: Bool = false
        private var lastRouteDistance: Double = 0
        private var lastSessionReadingCount: Int = 0
        
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
                        polyline.statusColor = UIColor(DesignSystem.cyan)
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
                polyline.statusColor = UIColor(DesignSystem.cyan)
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
