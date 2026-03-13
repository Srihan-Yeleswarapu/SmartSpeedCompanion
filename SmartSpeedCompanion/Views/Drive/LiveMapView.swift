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
        // Update tracking mode based on state
        let targetMode: MKUserTrackingMode = (viewModel.isRecording || viewModel.isNavigating) ? .followWithHeading : .follow
        
        if uiView.userTrackingMode != targetMode {
            uiView.setUserTrackingMode(targetMode, animated: true)
        }
        
        // Dynamic Camera logic for Premium Navigation experience
        updateSmartCamera(uiView)
    }
    
    private func updateSmartCamera(_ uiView: MKMapView) {
        let speed = viewModel.speed
        let distanceToTurn = viewModel.distanceToNextTurn
        let isNavigating = viewModel.isNavigating
        
        var targetAltitude: Double = 1000
        var targetPitch: Double = 0
        
        if isNavigating {
            // Navigation Mode: 3D perspective
            targetPitch = 60
            
            if distanceToTurn < 200 {
                // Approaching turn: zoom in deep
                targetAltitude = 150
            } else if speed > 50 {
                // Highway speeds: zoom out to see ahead
                targetAltitude = 800
            } else {
                // City driving
                targetAltitude = 400
            }
        } else if viewModel.isRecording {
            // Just recording: milder perspective
            targetPitch = 45
            targetAltitude = speed > 40 ? 1200 : 600
        } else {
            // Idle/Browsing: flat view
            targetPitch = 0
            targetAltitude = 1000
        }
        
        // Only update if difference is significant to avoid jitter
        let currentCamera = uiView.camera
        if abs(currentCamera.altitude - targetAltitude) > 50 || abs(currentCamera.pitch - targetPitch) > 5 {
            let newCamera = MKMapCamera(
                lookingAtCenter: uiView.userLocation.coordinate,
                fromDistance: targetAltitude,
                pitch: targetPitch,
                heading: uiView.userLocation.heading?.trueHeading ?? uiView.camera.heading
            )
            uiView.setCamera(newCamera, animated: true)
        }
    }
        
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
        
        init(_ parent: LiveMapView) {
            self.parent = parent
        }
        
        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? NavPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.statusColor
                renderer.lineWidth = 10.0 // Thicker, bolder lines for premium look
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
                    
                    // Create a custom icon for speed camera
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
