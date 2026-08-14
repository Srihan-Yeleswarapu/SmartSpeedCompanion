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
        var fingerprint = Hasher()
        fingerprint.combine(session.id)
        fingerprint.combine(session.readings.count)
        if let first = session.readings.first {
            fingerprint.combine(first.timestamp)
        }
        if let last = session.readings.last {
            fingerprint.combine(last.timestamp)
        }
        let renderedFingerprint = fingerprint.finalize()
        guard renderedFingerprint != context.coordinator.lastRenderedFingerprint else {
            return
        }
        context.coordinator.lastRenderedFingerprint = renderedFingerprint

        uiView.removeOverlays(uiView.overlays)
        
        var rect = MKMapRect.null
        
        // The XR reports show MapKit spending hundreds of milliseconds in
        // overlay creation on this screen. A heat map does not need one
        // MKCircle per GPS sample, so cap the first render at 300 evenly
        // spaced points. The stable fingerprint above ensures those overlays
        // are not rebuilt for unrelated SwiftUI updates.
        let readings = session.readings
        let count = readings.count
        let maxOverlayPoints = 300
        let strideValue = max(1, count / maxOverlayPoints)
        
        for i in stride(from: 0, to: count, by: strideValue) {
            let reading = readings[i]
            let coord = CLLocationCoordinate2D(latitude: reading.latitude, longitude: reading.longitude)
            let point = MKMapPoint(coord)
            let pointRect = MKMapRect(x: point.x, y: point.y, width: 0.1, height: 0.1)
            rect = rect.union(pointRect)
            
            let circle = HeatCircle(center: coord, radius: 12, isOver: reading.overLimit)
            uiView.addOverlay(circle)
        }
        
        if !rect.isNull {
            let padding = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
            uiView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public class Coordinator: NSObject, MKMapViewDelegate {
        var parent: OverspeedHeatMapView
        /// Analytics sits inside a tab that can re-render whenever the shared
        /// drive model publishes a GPS update. Rebuilding up to 1,000 circle
        /// overlays for each unrelated update blocks the same UIKit run loop
        /// as the live route renderer, so keep a stable session fingerprint.
        var lastRenderedFingerprint: Int?
        
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