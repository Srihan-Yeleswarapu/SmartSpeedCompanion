import SwiftUI
import MapKit

public struct LiveMapView: UIViewRepresentable {
    @EnvironmentObject var viewModel: DriveViewModel
    
    public init() {}
    
    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.mapType = .mutedStandard // Sleeker base for overlays
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.isPitchEnabled = true
        map.isRotateEnabled = true
        
        // Premium Apple Maps defaults
        let filter = MKPointOfInterestFilter(excluding: [.university, .school])
        map.pointOfInterestFilter = filter
        
        return map
    }
    
    public func updateUIView(_ uiView: MKMapView, context: Context) {
        // Block updates if searching to prevent "random zoom"
        if viewModel.isSearching || viewModel.isSearchingLocally {
            return
        }

        // If the user has manual control, clear restrictions and stop tracking
        if viewModel.isMapDetached {
            if uiView.cameraZoomRange != nil {
                uiView.setCameraZoomRange(nil, animated: true)
            }
            return
        }
        
        // Use manual camera management only if the user isn't interacting
        if !viewModel.isMapDetached {
            // Check if we have a valid location before moving the camera
            guard let userLoc = uiView.userLocation.location, 
                  CLLocationCoordinate2DIsValid(userLoc.coordinate),
                  userLoc.coordinate.latitude != 0 else { return }
            
            updateSmartCamera(uiView, context: context)
        }
        
        // Update overlays (History, Route, Cameras)
        updateOverlays(uiView)
    }
    
    private func updateOverlays(_ uiView: MKMapView) {
        // Clear all previous non-user overlays and annotations
        uiView.removeOverlays(uiView.overlays)
        uiView.removeAnnotations(uiView.annotations.filter { !($0 is MKUserLocation) })
        
        // Display Routes & Destination
        if viewModel.isNavigating, let route = viewModel.currentRoute {
            let polyline = NavPolyline(points: route.polyline.points(), count: route.polyline.pointCount)
            polyline.statusColor = UIColor(DesignSystem.cyan)
            uiView.addOverlay(polyline, level: .aboveRoads)
            
            if let dest = viewModel.destination {
                let annotation = MKPointAnnotation()
                annotation.coordinate = dest.placemark.coordinate
                annotation.title = dest.name
                uiView.addAnnotation(annotation)
            }
        }
        
        // Display Speed Cameras
        for camera in viewModel.nearbyCameras {
            let annotation = SpeedCameraAnnotation(camera: camera)
            uiView.addAnnotation(annotation)
        }
        
        // Display Retroactive History Line
        updateHistoryOverlays(uiView)
    }
    
    private func updateSmartCamera(_ uiView: MKMapView, context: Context) {
        let speed = viewModel.speed
        let distanceToTurn = viewModel.distanceToNextTurn
        let isNavigating = viewModel.isNavigating
        
        var targetAltitude: Double = 1000
        var targetPitch: Double = 0
        
        // --- Core Design Principle: Show exactly the amount of map needed for the next decision ---
        
        if isNavigating {
            targetPitch = 60 // 3D Perspective for navigation (Rule 7)
            
            // 1. Zoom In/Out based on Speed (Rule 1 & 4)
            // Speed-based zoom scaling (smooth dynamic scaling)
            switch speed {
            case 0..<3:
                targetAltitude = 200        // parked / red light
            case 3..<15:
                targetAltitude = 350        // parking lots / neighborhoods
            case 15..<30:
                targetAltitude = 600        // city streets
            case 30..<50:
                targetAltitude = 1000       // suburban roads
            case 50..<70:
                targetAltitude = 1800       // highways
            default:
                targetAltitude = 2600       // very high speed highways
            }
            
            // 2. Proximity to Turn (Rule 2)
            // Turn proximity zoom (progressive zoom)
            if distanceToTurn < 60 {
                targetAltitude = 120
            } else if distanceToTurn < 120 {
                targetAltitude = min(targetAltitude, 200)
            } else if distanceToTurn < 300 {
                targetAltitude = min(targetAltitude, 350)
            } else if distanceToTurn < 600 {
                targetAltitude = min(targetAltitude, 500)
            }
            
            // 3. Destination Approach (Rule 17 & 18)
            if let dest = viewModel.destination {
                let distToDest = uiView.userLocation.location?.distance(from: dest.placemark.location ?? CLLocation()) ?? 10000
                if distToDest < 150 {
                    targetAltitude = 90
                    targetPitch = 35
                } else if distToDest < 300 {
                    targetAltitude = 150
                    targetPitch = 40
                } else if distToDest < 600 {
                    targetAltitude = min(targetAltitude, 250)
                }
            }
            
            // 4. Highway Exit/Complex Interchanges (Rule 5 & 6)
            let instruction = viewModel.nextManeuverInstruction.lowercased()

            if instruction.contains("exit") ||
               instruction.contains("merge") ||
               instruction.contains("ramp") ||
               instruction.contains("fork") {
                
                targetAltitude = min(targetAltitude, 450)
            }

            // Long straight road zoom out
            if distanceToTurn > 2000 && speed > 50 {
                targetAltitude = max(targetAltitude, 2800)
            }

            // Gentle curve zoom
            if instruction.contains("turn") && distanceToTurn > 800 && speed < 50 {
                targetAltitude = min(targetAltitude, 1200)
            }

        } else if viewModel.isRecording {
            // Driving without navigation
            targetPitch = 45
            // Pure speed-based zoom (Rule 1)
            targetAltitude = speed > 60 ? 3000 : (speed > 30 ? 1500 : 800)
        } else {
            // Idle/Browsing
            targetPitch = 0
            targetAltitude = 2000
        }
        
        // 5. Hazards / Speed Cameras (Rule 15 & 16)
        if viewModel.activeCameraAlert != nil {
            targetAltitude = min(targetAltitude, 280)
            targetPitch = 50
        }
        
        // Apply camera with smooth animation if significant change detected
        let currentAltitude = uiView.camera.centerCoordinateDistance
        let altDiff = abs(currentAltitude - targetAltitude)
        
        // Ensure tracking mode is active for perfect centering (60fps native tracking)
        if uiView.userTrackingMode != .followWithHeading {
            uiView.setUserTrackingMode(.followWithHeading, animated: true)
        }
        
        // Update altitude natively without breaking tracking mode via CameraZoomRange
        if altDiff > 60 || abs(uiView.camera.pitch - targetPitch) > 2 {
            let zoomRange = MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: targetAltitude,
                maxCenterCoordinateDistance: targetAltitude
            )
            uiView.setCameraZoomRange(zoomRange, animated: true)
            
            // Apply pitch while maintaining tracking
            let newCamera = uiView.camera
            newCamera.pitch = targetPitch
            uiView.setCamera(newCamera, animated: true)
        }
    }
        

    
    private func updateHistoryOverlays(_ uiView: MKMapView) {
        if let session = viewModel.sessionRecorder.currentSession, !session.readings.isEmpty {
            var safeCoords: [CLLocationCoordinate2D] = []
            var overCoords: [CLLocationCoordinate2D] = []
            
            for reading in session.readings {
                let coord = CLLocationCoordinate2D(latitude: reading.latitude, longitude: reading.longitude)
                if reading.overLimit {
                    if !safeCoords.isEmpty {
                        let polyline = NavPolyline(coordinates: safeCoords, count: safeCoords.count)
                        polyline.statusColor = UIColor(DesignSystem.cyan)
                        uiView.addOverlay(polyline, level: .aboveRoads)
                        safeCoords.removeAll()
                    }
                    overCoords.append(coord)
                } else {
                    if !overCoords.isEmpty {
                        let polyline = NavPolyline(coordinates: overCoords, count: overCoords.count)
                        polyline.statusColor = UIColor(DesignSystem.alertRed)
                        uiView.addOverlay(polyline, level: .aboveRoads)
                        overCoords.removeAll()
                    }
                    safeCoords.append(coord)
                }
            }
            if !safeCoords.isEmpty {
                let polyline = NavPolyline(coordinates: safeCoords, count: safeCoords.count)
                polyline.statusColor = UIColor(DesignSystem.cyan)
                uiView.addOverlay(polyline, level: .aboveRoads)
            }
            if !overCoords.isEmpty {
                let polyline = NavPolyline(coordinates: overCoords, count: overCoords.count)
                polyline.statusColor = UIColor(DesignSystem.alertRed)
                uiView.addOverlay(polyline, level: .aboveRoads)
            }
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public class Coordinator: NSObject, MKMapViewDelegate {
        var parent: LiveMapView
        private var interactionTimer: Timer?
        
        init(_ parent: LiveMapView) {
            self.parent = parent
        }
        
        public func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Check if the change was initiated by the user (not code-driven)
            if let gestureRecognizers = mapView.subviews.first?.gestureRecognizers {
                for gesture in gestureRecognizers {
                    if gesture.state == .began || gesture.state == .changed {
                        startManualMode()
                        return
                    }
                }
            }
        }
        
        public func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            if mode == .none && !parent.viewModel.isMapDetached {
                startManualMode()
            }
        }
        
        private func startManualMode() {
            parent.viewModel.isMapDetached = true
            interactionTimer?.invalidate()
            // Auto-resume navigation zoom after 10 seconds of inactivity
            interactionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.parent.viewModel.isMapDetached = false
                }
            }
        }
        
        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? NavPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.statusColor
                renderer.lineWidth = 10.0
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
        
        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cameraAnnotation = annotation as? SpeedCameraAnnotation {
                let identifier = "SpeedCamera"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if view == nil {
                    view = MKAnnotationView(annotation: cameraAnnotation, reuseIdentifier: identifier)
                    view?.canShowCallout = true
                    
                    let imageView = UIImageView(image: UIImage(systemName: "camera.badge.ellipsis"))
                    imageView.tintColor = .white
                    imageView.backgroundColor = UIColor(DesignSystem.alertRed)
                    imageView.layer.cornerRadius = 16
                    imageView.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
                    imageView.contentMode = .center
                    view?.addSubview(imageView)
                    view?.frame = imageView.frame
                } else {
                    view?.annotation = cameraAnnotation
                }
                return view
            }
            return nil
        }
    }
}

class SpeedCameraAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    
    init(camera: SpeedCamera) {
        self.coordinate = CLLocationCoordinate2D(latitude: camera.latitude, longitude: camera.longitude)
        self.title = "Speed Camera"
        self.subtitle = camera.location ?? camera.roadway
    }
}

class NavPolyline: MKPolyline {
    var statusColor: UIColor = .systemBlue
}
