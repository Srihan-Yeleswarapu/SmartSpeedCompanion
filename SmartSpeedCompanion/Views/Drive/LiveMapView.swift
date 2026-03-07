import SwiftUI
import MapKit
import Combine

public struct LiveMapView: UIViewRepresentable {
    @EnvironmentObject var viewModel: DriveViewModel
    
    public func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.overrideUserInterfaceStyle = .dark
        map.mapType = .standard // Changed to standard for clearer navigation polylines
        map.showsUserLocation = true
        map.userTrackingMode = .followWithHeading
        map.showsCompass = true
        map.showsScale = true
        
        // Add Recalculating overlay view hooks via coordinator
        return map
    }
    
    public func updateUIView(_ uiView: MKMapView, context: Context) {
        uiView.removeOverlays(uiView.overlays)
        uiView.removeAnnotations(uiView.annotations.filter { !($0 is MKUserLocation) })
        
        // 1. Render active navigation route
        if viewModel.isNavigating, let route = viewModel.currentRoute {
            let polyline = NavPolyline(points: route.polyline.points(), count: route.polyline.pointCount)
            polyline.statusColor = UIColor(DesignSystem.cyan) // Simulated safe color
            uiView.addOverlay(polyline)
            
            // Show destination pin
            if let dest = viewModel.destination {
                let annotation = MKPointAnnotation()
                annotation.coordinate = dest.placemark.coordinate
                annotation.title = dest.name
                uiView.addAnnotation(annotation)
            }
        } else if let session = viewModel.sessionRecorder.currentSession {
            // 2. Render standard drive session history line
            var safeCoords: [CLLocationCoordinate2D] = []
            var overCoords: [CLLocationCoordinate2D] = []
            
            for reading in session.readings {
                let coord = CLLocationCoordinate2D(latitude: reading.latitude, longitude: reading.longitude)
                if reading.overLimit {
                    if !safeCoords.isEmpty {
                        let polyline = NavPolyline(coordinates: safeCoords, count: safeCoords.count)
                        polyline.statusColor = UIColor(DesignSystem.neonGreen) // Safe
                        uiView.addOverlay(polyline)
                        safeCoords.removeAll()
                    }
                    overCoords.append(coord)
                } else {
                    if !overCoords.isEmpty {
                        let polyline = NavPolyline(coordinates: overCoords, count: overCoords.count)
                        polyline.statusColor = UIColor(DesignSystem.alertRed) // Over
                        uiView.addOverlay(polyline)
                        overCoords.removeAll()
                    }
                    safeCoords.append(coord)
                }
            }
            if !safeCoords.isEmpty {
                let polyline = NavPolyline(coordinates: safeCoords, count: safeCoords.count)
                polyline.statusColor = UIColor(DesignSystem.neonGreen)
                uiView.addOverlay(polyline)
            }
            if !overCoords.isEmpty {
                let polyline = NavPolyline(coordinates: overCoords, count: overCoords.count)
                polyline.statusColor = UIColor(DesignSystem.alertRed)
                uiView.addOverlay(polyline)
            }
        }
        
        // 3. Render Speed Limit Sign Annotation at current projected path (simulated near location)
        if let currentLoc = viewModel.locationManager.latestLocation {
            let sign = SpeedLimitAnnotation(coordinate: currentLoc.coordinate, limit: viewModel.limit, source: viewModel.speedLimitSource)
            uiView.addAnnotation(sign)
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
        
        // Custom Annotations and Line Renderings
        public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil } // Use default blue glow or custom car
            
            if let signAnnotation = annotation as? SpeedLimitAnnotation {
                let identifier = "SpeedLimitSign"
                var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                if view == nil {
                    view = MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                }
                view?.image = createSpeedSignImage(limit: signAnnotation.limit)
                view?.centerOffset = CGPoint(x: 30, y: -30) // Offset to not hide car
                return view
            }
            
            return nil
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
        
        private func createSpeedSignImage(limit: Int) -> UIImage {
            let size = CGSize(width: 40, height: 40)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { ctx in
                let circleRect = CGRect(x: 2, y: 2, width: 36, height: 36)
                
                // White background
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: circleRect)
                
                // Red Border
                UIColor.systemRed.setStroke()
                ctx.cgContext.setLineWidth(4)
                ctx.cgContext.strokeEllipse(in: circleRect)
                
                // Black Text
                let text = "\(limit)"
                let font = UIFont.systemFont(ofSize: 18, weight: .bold)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor.black
                ]
                let textSize = text.size(withAttributes: attributes)
                let textRect = CGRect(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2, width: textSize.width, height: textSize.height)
                text.draw(in: textRect, withAttributes: attributes)
            }
        }
    }
}

class NavPolyline: MKPolyline {
    var statusColor: UIColor = .systemBlue
}

class SpeedLimitAnnotation: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    var limit: Int
    var source: String
    
    init(coordinate: CLLocationCoordinate2D, limit: Int, source: String) {
        self.coordinate = coordinate
        self.limit = limit
        self.source = source
    }
}
