#if DEBUG || DEVELOPER_BUILD
import SwiftUI
import MapKit

/// A view for the Driver Simulator that allows manual override of GPS data.
public struct DeveloperSimulatorView: View {
    @StateObject private var sim = SimulationManager.shared
    @ObservedObject var locationManager: LocationManager
    
    public init(locationManager: LocationManager) {
        self.locationManager = locationManager
    }
    
    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading) {
                    Text("DRIVER SIMULATOR")
                        .font(.system(size: 14, weight: .black, design: .monospaced))
                        .foregroundColor(DesignSystem.cyan)
                    Text("GPS OVERRIDE SYSTEM")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.gray)
                }
                Spacer()
                Toggle("", isOn: $locationManager.isMockMode)
                    .labelsHidden()
            }
            .padding(.bottom, 5)
            
            if locationManager.isMockMode {
                VStack(spacing: 20) {
                    // Control Button
                    Button(action: {
                        sim.isSimulationActive.toggle()
                    }) {
                        HStack {
                            Image(systemName: sim.isSimulationActive ? "stop.fill" : "play.fill")
                            Text(sim.isSimulationActive ? "STOP DRIVING" : "START DRIVING")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(sim.isSimulationActive ? DesignSystem.alertRed : DesignSystem.neonGreen)
                        .foregroundColor(.black)
                        .cornerRadius(8)
                    }
                    
                    // Map Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LOCATION")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.gray)
                        
                        MockMapView(sim: sim)
                            .frame(height: 180)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                        
                        Text("Drag the red pin to set the mock car position.")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                    
                    // Heading Dial
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("HEADING")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(Int(sim.mockHeading))°")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(DesignSystem.cyan)
                        }
                        
                        Slider(value: $sim.mockHeading, in: 0...359, step: 1)
                            .accentColor(DesignSystem.cyan)
                    }
                    
                    // Speed Slider (Custom Style)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("MOCK SPEED")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(Int(sim.mockSpeed)) mph")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(DesignSystem.amber)
                        }
                        
                        ZStack(alignment: .leading) {
                            // Track background
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(0.08))
                                .frame(height: 4)

                            // Filled portion
                            GeometryReader { geo in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(DesignSystem.amber)
                                    .frame(width: geo.size.width * CGFloat(sim.mockSpeed / 100.0), height: 4)
                            }
                            .frame(height: 4)

                            // Invisible system slider for input
                            Slider(value: $sim.mockSpeed, in: 0...100, step: 1)
                                .opacity(0.015)
                        }
                        .frame(height: 20)
                        
                        HStack {
                            Text("0")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.gray)
                            Spacer()
                            Text("100")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.gray)
                        }
                    }
                }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.gray.opacity(0.3))
                    
                    Text("Mock Mode is inactive. Enable GPS override above to manually control speed and location data.")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .padding()
        .background(DesignSystem.bgCard)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

/// A simplified Map wrapper for the simulator to allow dragging a pin.
struct MockMapView: UIViewRepresentable {
    @ObservedObject var sim: SimulationManager
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.overrideUserInterfaceStyle = .dark
        
        let annotation = MKPointAnnotation()
        annotation.coordinate = sim.mockCoordinate
        mapView.addAnnotation(annotation)
        
        // Initial zoom
        let region = MKCoordinateRegion(
            center: sim.mockCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        )
        mapView.setRegion(region, animated: false)
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Sync annotation to mockCoordinate if it changed externally (not from drag)
        if let annotation = uiView.annotations.first as? MKPointAnnotation {
            if abs(annotation.coordinate.latitude - sim.mockCoordinate.latitude) > 0.000001 ||
               abs(annotation.coordinate.longitude - sim.mockCoordinate.longitude) > 0.000001 {
                annotation.coordinate = sim.mockCoordinate
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MockMapView
        
        init(_ parent: MockMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            
            let identifier = "SimulatorPin"
            var view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
            
            if view == nil {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view?.isDraggable = true
                view?.markerTintColor = .systemRed
                view?.glyphImage = UIImage(systemName: "car.fill")
            } else {
                view?.annotation = annotation
            }
            
            return view
        }
        
        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, didChange newState: MKAnnotationView.DragState, fromOldState oldState: MKAnnotationView.DragState) {
            if newState == .ending {
                if let newCoord = view.annotation?.coordinate {
                    DispatchQueue.main.async {
                        self.parent.sim.mockCoordinate = newCoord
                    }
                }
            }
        }
    }
}
#endif
