// Path: Views/Drive/LiveMapView.swift
import SwiftUI
import MapKit
import Combine

public struct LiveMapView: UIViewRepresentable {
    @EnvironmentObject var viewModel: DriveViewModel
    
    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.mapType = .hybrid
        map.showsUserLocation = true
        map.userTrackingMode = .followWithHeading
        map.layer.cornerRadius = 16
        map.clipsToBounds = true
        return map
    }
    
    public func updateUIView(_ uiView: MKMapView, context: Context) {
        // Sync polyline overlays representing the session trail
        guard let session = viewModel.sessionRecorder.currentSession else {
            uiView.removeOverlays(uiView.overlays)
            return
        }
        
        // Rebuilding polylines logic (inefficient for millions of points, but fine here)
        uiView.removeOverlays(uiView.overlays) // Remove all, prep for color-segment recreation
        
        var safeCoords: [CLLocationCoordinate2D] = []
        var overCoords: [CLLocationCoordinate2D] = []
        
        // Break session readings down into safe/over segments
        for reading in session.readings {
            let coord = CLLocationCoordinate2D(latitude: reading.latitude, longitude: reading.longitude)
            if reading.overLimit {
                if !safeCoords.isEmpty {
                    let polyline = StatusPolyline(coordinates: safeCoords, count: safeCoords.count)
                    polyline.statusColor = UIColor(DesignSystem.cyan)
                    uiView.addOverlay(polyline)
                    safeCoords.removeAll()
                }
                overCoords.append(coord)
            } else {
                if !overCoords.isEmpty {
                    let polyline = StatusPolyline(coordinates: overCoords, count: overCoords.count)
                    polyline.statusColor = UIColor(DesignSystem.alertRed)
                    uiView.addOverlay(polyline)
                    overCoords.removeAll()
                }
                safeCoords.append(coord)
            }
        }
        
        // Add trailing tails
        if !safeCoords.isEmpty {
            let polyline = StatusPolyline(coordinates: safeCoords, count: safeCoords.count)
            polyline.statusColor = UIColor(DesignSystem.cyan)
            uiView.addOverlay(polyline)
        }
        if !overCoords.isEmpty {
            let polyline = StatusPolyline(coordinates: overCoords, count: overCoords.count)
            polyline.statusColor = UIColor(DesignSystem.alertRed)
            uiView.addOverlay(polyline)
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
        
        // Replace blue dot with custom glowing annotation
        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let identifier = "UserLocation"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                    let circle = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
                    circle.backgroundColor = UIColor(DesignSystem.cyan)
                    circle.layer.cornerRadius = 8
                    circle.layer.shadowColor = UIColor(DesignSystem.cyan).cgColor
                    circle.layer.shadowRadius = 12
                    circle.layer.shadowOpacity = 1.0
                    circle.layer.shadowOffset = .zero
                    view?.addSubview(circle)
                    view?.frame = circle.frame
                }
                return view
            }
            return nil
        }
        
        // Color line renderer
        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? StatusPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polyline.statusColor
                renderer.lineWidth = 4.0
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// Subclass allows attaching a color state to the polyline for the renderer
class StatusPolyline: MKPolyline {
    var statusColor: UIColor = .cyan
}
