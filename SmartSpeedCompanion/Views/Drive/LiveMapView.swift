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
        // Update tracking and Camera
        if viewModel.isRecording || viewModel.isNavigating {
            if uiView.userTrackingMode != .followWithHeading {
                uiView.setUserTrackingMode(.followWithHeading, animated: true)
            }
            
            // 3D Perspective Camera
            let camera = MKMapCamera(
                lookingAtCenter: uiView.userLocation.coordinate,
                fromDistance: 400,
                pitch: 60,
                heading: uiView.userLocation.heading?.trueHeading ?? 0
            )
            uiView.setCamera(camera, animated: true)
            
        } else {
            if uiView.userTrackingMode != .follow {
                uiView.setUserTrackingMode(.follow, animated: true)
            }
            // Reset to flat view when not navigating
            let camera = MKMapCamera(
                lookingAtCenter: uiView.userLocation.coordinate,
                fromDistance: 1000,
                pitch: 0,
                heading: 0
            )
            uiView.setCamera(camera, animated: true)
        }
        
        // Clear all previous non-user overlays and annotations
        uiView.removeOverlays(uiView.overlays)
        uiView.removeAnnotations(uiView.annotations.filter { !($0 is MKUserLocation) })
        
        // Display Route
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
    }
}

class NavPolyline: MKPolyline {
    var statusColor: UIColor = .systemBlue
}
