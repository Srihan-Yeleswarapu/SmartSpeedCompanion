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

        // Update tracking mode and camera only if not manually interacting
        if !context.coordinator.isUserInteracting {
            let targetMode: MKUserTrackingMode = (viewModel.isRecording || viewModel.isNavigating) ? .followWithHeading : .follow
            if uiView.userTrackingMode != targetMode {
                uiView.setUserTrackingMode(targetMode, animated: true)
            }
            
            // Dynamic Camera logic based on sophisticated rules
            updateSmartCamera(uiView, context: context)
        }
        
        // Update overlays (always keep these fresh)
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
            if speed > 60 { // Highway speeds
                targetAltitude = 2500 // Wide zoom to see ahead
            } else if speed > 40 {
                targetAltitude = 1200
            } else if speed < 5 { // Slower/Stopped (Rule 19)
                targetAltitude = 250 // Precise detail at red lights/intersections
            } else {
                targetAltitude = 600 // City standard (Rule 8)
            }
            
            // 2. Proximity to Turn (Rule 2)
            if distanceToTurn < 100 { // ~300 feet: Final approach
                targetAltitude = 150 // Deep zoom for road geometry
            } else if distanceToTurn < 250 { // ~800 feet: Preparing
                targetAltitude = min(targetAltitude, 350) 
            }
            
            // 3. Destination Approach (Rule 17 & 18)
            if let dest = viewModel.destination {
                let distToDest = uiView.userLocation.location?.distance(from: dest.placemark.location ?? CLLocation()) ?? 10000
                if distToDest < 320 { // within ~0.2 miles
                    targetAltitude = 150
                    targetPitch = 45 // Lower pitch for final visibility
                }
            }
            
            // 4. Highway Exit/Complex Interchanges (Rule 5 & 6)
            if viewModel.nextManeuverInstruction.lowercased().contains("exit") || 
               viewModel.nextManeuverInstruction.lowercased().contains("merge") {
                targetAltitude = min(targetAltitude, 500) // Moderate zoom for clarity
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
            targetAltitude = min(targetAltitude, 400) // Highlight the camera area
        }
        
        // Apply camera with smooth animation if significant change detected
        let currentCamera = uiView.camera
        if abs(currentCamera.altitude - targetAltitude) > 30 || abs(currentCamera.pitch - targetPitch) > 5 {
            let newCamera = MKMapCamera(
                lookingAtCenter: uiView.userLocation.coordinate,
                fromDistance: targetAltitude,
                pitch: targetPitch,
                heading: uiView.userLocation.heading?.trueHeading ?? uiView.camera.heading
            )
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
        public var isUserInteracting: Bool = false
        private var interactionTimer: Timer?
        
        init(_ parent: LiveMapView) {
            self.parent = parent
        }
        
        public func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            // Check if the region change was initiated by a gesture (manual)
            let view = mapView.subviews.first { $0.gestureRecognizers?.contains { $0.state == .began || $0.state == .changed } ?? false }
            if view != nil {
                startManualMode()
            }
        }
        
        private func startManualMode() {
            isUserInteracting = true
            interactionTimer?.invalidate()
            // Auto-resume navigation zoom after 10 seconds of inactivity
            interactionTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
                self?.isUserInteracting = false
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
