// Path: Views/Analytics/OverspeedHeatMapView.swift
import SwiftUI
import MapKit

public struct OverspeedHeatMapView: UIViewRepresentable {
    let session: DriveSession
    
    public func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = .dark
        mapView.isScrollEnabled = true
        mapView.isZoomEnabled = true
        return mapView
    }
    
    public func updateUIView(_ uiView: MKMapView, context: Context) {
        // Simple map diffing strategy (clear and replace).
        // Since analytics is typically static per-session view, simple replacement is acceptable here.
        uiView.removeOverlays(uiView.overlays)
        
        var rect = MKMapRect.null
        
        for reading in session.readings {
            let coord = CLLocationCoordinate2D(latitude: reading.latitude, longitude: reading.longitude)
            let point = MKMapPoint(coord)
            let pointRect = MKMapRect(x: point.x, y: point.y, width: 0.1, height: 0.1)
            rect = rect.union(pointRect)
            
            // MapKit Circles
            let circle = HeatCircle(center: coord, radius: 12, isOver: reading.overLimit)
            uiView.addOverlay(circle)
        }
        
        if !rect.isNull {
            // First load zoom fix
            let padding = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
            uiView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public class Coordinator: NSObject, MKMapViewDelegate {
        var parent: OverspeedHeatMapView
        
        init(_ parent: OverspeedHeatMapView) {
            self.parent = parent
        }
        
        public func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? HeatCircle {
                let renderer = MKCircleRenderer(circle: circle)
                
                if circle.isOver {
                    renderer.fillColor = UIColor(DesignSystem.alertRed).withAlphaComponent(0.75)
                    renderer.strokeColor = UIColor(DesignSystem.alertRed).withAlphaComponent(0.9)
                } else {
                    renderer.fillColor = UIColor(DesignSystem.neonGreen).withAlphaComponent(0.65)
                    renderer.strokeColor = UIColor(DesignSystem.neonGreen).withAlphaComponent(0.9)
                }
                
                renderer.lineWidth = 1.0
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

class HeatCircle: MKCircle {
    var isOver: Bool = false
    convenience init(center: CLLocationCoordinate2D, radius: CLLocationDistance, isOver: Bool) {
        self.init(center: center, radius: radius)
        self.isOver = isOver
    }
}
