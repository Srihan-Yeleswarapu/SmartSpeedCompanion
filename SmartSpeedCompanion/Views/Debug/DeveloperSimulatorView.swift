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
                    
                    HStack(spacing: 30) {
                        // Heading Dial (Compass)
                        VStack(spacing: 12) {
                            Text("HEADING")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            CompassHeadingPicker(heading: $sim.mockHeading)
                            
                            Text("\(Int(sim.mockHeading))°")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundColor(DesignSystem.cyan)
                        }
                        
                        // Speed Slider (Custom Style)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("MOCK SPEED")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            Spacer()
                            
                            VStack(spacing: 8) {
                                Text("\(Int(sim.mockSpeed)) mph")
                                    .font(.system(size: 18, weight: .black, design: .monospaced))
                                    .foregroundColor(DesignSystem.amber)
                                
                                ZStack(alignment: .bottom) {
                                    // Vertical Track background
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white.opacity(0.08))
                                        .frame(width: 40, height: 120)

                                    // Filled portion
                                    GeometryReader { geo in
                                        VStack {
                                            Spacer(minLength: 0)
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(DesignSystem.amber)
                                                .frame(width: 40, height: 120 * CGFloat(sim.mockSpeed / 100.0))
                                        }
                                    }
                                    .frame(width: 40, height: 120)

                                    // Invisible slider for input (overlaying the vertical area)
                                    // We'll use a standard slider rotated for verticality or just a gesture
                                    Rectangle()
                                        .fill(Color.white.opacity(0.001))
                                        .frame(width: 60, height: 120)
                                        .gesture(
                                            DragGesture(minimumDistance: 0)
                                                .onChanged { value in
                                                    let percent = 1.0 - (value.location.y / 120.0)
                                                    sim.mockSpeed = max(0, min(100, Double(percent * 100)))
                                                }
                                        )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 10)
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

/// A custom compass dial to pick heading.
struct CompassHeadingPicker: View {
    @Binding var heading: Double
    
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.05))
                .frame(width: 100, height: 100)
            
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 2)
                .frame(width: 100, height: 100)
            
            // Marks
            ForEach(0..<12) { i in
                Rectangle()
                    .fill(i % 3 == 0 ? DesignSystem.cyan.opacity(0.5) : Color.white.opacity(0.2))
                    .frame(width: i % 3 == 0 ? 3 : 1, height: i % 3 == 0 ? 10 : 6)
                    .offset(y: -44)
                    .rotationEffect(.degrees(Double(i) * 30))
            }
            
            // The Arrow
            VStack(spacing: 0) {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 16))
                    .foregroundColor(DesignSystem.cyan)
                Rectangle()
                    .fill(DesignSystem.cyan)
                    .frame(width: 2, height: 30)
            }
            .offset(y: -15)
            .rotationEffect(.degrees(heading))
            .shadow(color: DesignSystem.cyan.opacity(0.5), radius: 5)
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let vector = CGVector(dx: value.location.x - 50, dy: value.location.y - 50)
                    let angle = atan2(vector.dy, vector.dx)
                    var degrees = angle * 180 / .pi + 90
                    while degrees < 0 { degrees += 360 }
                    while degrees >= 360 { degrees -= 360 }
                    heading = degrees
                }
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
        
        // Add Simulated Car annotation
        let annotation = MKPointAnnotation()
        annotation.coordinate = sim.mockCoordinate
        annotation.title = "SIMULATOR_DRAGGABLE"
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
        // Find the draggable pin
        if let annotation = uiView.annotations.first(where: { $0.title == "SIMULATOR_DRAGGABLE" }) as? MKPointAnnotation {
            // Only update if not currently dragging (to avoid fighting the user)
            // But SimulationManager might update it via drive() logic, so we DO want to update it.
            // However, we should check if the difference is significant.
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
