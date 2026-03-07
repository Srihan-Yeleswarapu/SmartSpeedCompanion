import SwiftUI
import MapKit

public struct LiveMapView: UIViewRepresentable {
    @EnvironmentObject var viewModel: DriveViewModel
    
    public init() {}
    
    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.mapType = .standard
        map.showsUserLocation = true
        
        // Settings requested
        map.showsCompass = true
        map.showsScale = true
        
        return map
    }
    
    public func updateUIView(_ uiView: MKMapView, context: Context) {
        // Update tracking mode
        if viewModel.isRecording || viewModel.isNavigating {
            if uiView.userTrackingMode != .followWithHeading {
                uiView.setUserTrackingMode(.followWithHeading, animated: true)
            }
            if let cam = uiView.camera.copy() as? MKMapCamera {
                cam.altitude = 500 // ~zoom level for driving
                uiView.setCamera(cam, animated: true)
            }
        } else {
            if uiView.userTrackingMode != .follow {
                uiView.setUserTrackingMode(.follow, animated: true)
            }
        }
        
        // Clear all previous non-user overlays and annotations
        uiView.removeOverlays(uiView.overlays)
        uiView.removeAnnotations(uiView.annotations.filter { !($0 is MKUserLocation) })
        
        // Display Route
        if viewModel.isNavigating, let route = viewModel.currentRoute {
            let polyline = NavPolyline(points: route.polyline.points(), count: route.polyline.pointCount)
            polyline.statusColor = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0) // #00D4FF setup
            uiView.addOverlay(polyline)
            
            if let dest = viewModel.destination {
                let annotation = MKPointAnnotation()
                annotation.coordinate = dest.placemark.coordinate
                annotation.title = dest.name
                uiView.addAnnotation(annotation)
            }
        }
        
        // Display Retroactive History Line
        if let session = viewModel.sessionRecorder.currentSession, !session.readings.isEmpty {
            var safeCoords: [CLLocationCoordinate2D] = []
            var overCoords: [CLLocationCoordinate2D] = []
            
            for reading in session.readings {
                let coord = CLLocationCoordinate2D(latitude: reading.latitude, longitude: reading.longitude)
                if reading.overLimit {
                    if !safeCoords.isEmpty {
                        let polyline = NavPolyline(coordinates: safeCoords, count: safeCoords.count)
                        polyline.statusColor = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0) // Safe Cyan
                        uiView.addOverlay(polyline)
                        safeCoords.removeAll()
                    }
                    overCoords.append(coord)
                } else {
                    if !overCoords.isEmpty {
                        let polyline = NavPolyline(coordinates: overCoords, count: overCoords.count)
                        polyline.statusColor = UIColor(red: 1.0, green: 0.24, blue: 0.44, alpha: 1.0) // Over Red
                        uiView.addOverlay(polyline)
                        overCoords.removeAll()
                    }
                    safeCoords.append(coord)
                }
            }
            if !safeCoords.isEmpty {
                let polyline = NavPolyline(coordinates: safeCoords, count: safeCoords.count)
                polyline.statusColor = UIColor(red: 0.0, green: 0.83, blue: 1.0, alpha: 1.0)
                uiView.addOverlay(polyline)
            }
            if !overCoords.isEmpty {
                let polyline = NavPolyline(coordinates: overCoords, count: overCoords.count)
                polyline.statusColor = UIColor(red: 1.0, green: 0.24, blue: 0.44, alpha: 1.0)
                uiView.addOverlay(polyline)
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
                renderer.lineWidth = 6.0
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

class NavPolyline: MKPolyline {
    var statusColor: UIColor = .systemBlue
}
