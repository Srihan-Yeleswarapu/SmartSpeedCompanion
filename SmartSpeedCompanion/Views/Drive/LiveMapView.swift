import SwiftUI
import MapKit

public struct LiveMapView: UIViewRepresentable {
    @EnvironmentObject var viewModel: DriveViewModel
    
    public init() {}
    
    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.mapType = .mutedStandard
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        
        // Use native tracking with heading for best centering reliability
        map.userTrackingMode = .followWithHeading
        
        // Add gesture detection for manual mode
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleManualInteraction(_:)))
        pan.delegate = context.coordinator
        map.addGestureRecognizer(pan)
        
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleManualInteraction(_:)))
        pinch.delegate = context.coordinator
        map.addGestureRecognizer(pinch)
        
        // Minimal POI filter for performance
        let filter = MKPointOfInterestFilter(excluding: [.university, .school])
        map.pointOfInterestFilter = filter
        
        return map
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
        
        var targetAltitude: Double = 1000
        var targetPitch: Double = 0
        
        if isNavigating {
            targetPitch = 45
            
            switch speed {
            case 0..<3:
                targetAltitude = 250
            case 3..<15:
                targetAltitude = 400
            case 15..<30:
                targetAltitude = 700
            case 30..<50:
                targetAltitude = 1100
            case 50..<70:
                targetAltitude = 1900
            default:
                targetAltitude = 2800
            }
            
            // Turn proximity override
            if distanceToTurn < 60 {
                targetAltitude = 150
            } else if distanceToTurn < 120 {
                targetAltitude = min(targetAltitude, 250)
            } else if distanceToTurn < 300 {
                targetAltitude = min(targetAltitude, 400)
            } else if distanceToTurn < 600 {
                targetAltitude = min(targetAltitude, 600)
            }
            
            // Destination approach
            if let dest = viewModel.destination {
                let destLoc = dest.placemark.location ?? CLLocation()
                let distToDest = uiView.userLocation.location?.distance(from: destLoc) ?? 10000
                if distToDest < 150 {
                    targetAltitude = 100
                    targetPitch = 30
                } else if distToDest < 300 {
                    targetAltitude = 180
                    targetPitch = 35
                }
            }
            
            // Highway / complex interchange — show a bit more
            let instruction = viewModel.nextManeuverInstruction.lowercased()
            if instruction.contains("exit") || instruction.contains("merge") ||
               instruction.contains("ramp") || instruction.contains("fork") {
                targetAltitude = min(targetAltitude, 500)
            }
            
            // Long straight road at high speed — zoom out
            if distanceToTurn > 2000 && speed > 50 {
                targetAltitude = max(targetAltitude, 3000)
            }
            
        } else if viewModel.isRecording {
            // Driving without navigation
            targetPitch = 35
            targetAltitude = speed > 60 ? 3000 : (speed > 30 ? 1600 : 900)
        } else {
            // Idle/Browsing overview
            targetPitch = 0
            targetAltitude = 2000
        }
        
        // Only animate if there is a meaningful difference (prevents micro-jitter)
        let currentAltitude = uiView.camera.centerCoordinateDistance
        let currentPitch = Double(uiView.camera.pitch)
        let altDiff = abs(currentAltitude - targetAltitude)
        let pitchDiff = abs(currentPitch - targetPitch)
        
        // Apply camera changes if needed
        if altDiff > 80 || pitchDiff > 8 {
            let newCamera = uiView.camera.copy() as! MKMapCamera
            newCamera.centerCoordinateDistance = targetAltitude
            newCamera.pitch = CGFloat(targetPitch)
            
            // Allow MapKit to handle its own animation for smoother results
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
            
            let routeChanged = isNavigating != lastIsNavigating || currentRouteDistance != lastRouteDistance
            let historyChanged = currentReadingCount != lastHistoryCounts.safeCount + lastHistoryCounts.overCount
            
            guard routeChanged || historyChanged else { return }
            
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
                let polyline = NavPolyline(points: route.polyline.points(), count: route.polyline.pointCount)
                polyline.statusColor = UIColor(DesignSystem.cyan)
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
                renderer.lineWidth = 8.0
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
}
