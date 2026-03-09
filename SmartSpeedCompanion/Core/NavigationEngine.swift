// Path: Core/NavigationEngine.swift
import Foundation
import MapKit
import Combine
import AVFoundation

@MainActor
public class NavigationEngine: ObservableObject {
    public static let shared = NavigationEngine()
    
    @Published public var currentRoute: MKRoute?
    @Published public var alternativeRoutes: [MKRoute] = []
    @Published public var nextManeuverInstruction: String = ""
    @Published public var nextManeuverDistance: CLLocationDistance = 0
    @Published public var eta: Date?
    @Published public var remainingDistance: CLLocationDistance = 0
    @Published public var isRerouting: Bool = false
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var currentStepIndex: Int = 0
    
    private init() {}
    
    public func search(query: String, region: MKCoordinateRegion) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        
        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()
            return response.mapItems
        } catch {
            print("[Search] Error: \(error)")
            return []
        }
    }
    
    public func calculateRoute(from start: MKMapItem, to destination: MKMapItem) async {
        let request = MKDirections.Request()
        request.source = start
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        
        let directions = MKDirections(request: request)
        do {
            let response = try await directions.calculate()
            if let primary = response.routes.first {
                self.currentRoute = primary
                self.alternativeRoutes = Array(response.routes.dropFirst())
                self.eta = Date().addingTimeInterval(primary.expectedTravelTime)
                self.remainingDistance = primary.distance
                self.currentStepIndex = 0
                updateManeuver()
            }
        } catch {
            print("[Navigation] Route calculation error: \(error)")
        }
    }
    
    public func updateProgress(location: CLLocation) {
        guard let route = currentRoute else { return }
        
        // Find nearest point on active polyline and check for >80m deviation
        let distanceToRoute = distance(from: location.coordinate, to: route.polyline)
        if distanceToRoute > 80.0 && !isRerouting {
            triggerReroute(from: location)
            return
        }
        
        // Progress steps (simple heuristic)
        if currentStepIndex < route.steps.count {
            let step = route.steps[currentStepIndex]
            let dist = location.distance(from: CLLocation(latitude: step.polyline.coordinate.latitude, longitude: step.polyline.coordinate.longitude))
            
            self.nextManeuverDistance = dist
            self.remainingDistance = max(0, self.remainingDistance - location.speed) // simplified
            
            if dist < 30 {
                // Next step
                currentStepIndex += 1
                updateManeuver()
            } else if dist < 500 && dist > 480 {
                speak("In 500 meters, \(step.instructions)")
            }
        } else {
            speak("You have arrived at your destination.")
            clearRoute()
        }
    }
    
    private func triggerReroute(from location: CLLocation) {
        isRerouting = true
        speak("Recalculating...")
        // For MVP, just clear it or we could attempt full recalculate
        // clearRoute()
    }
    
    private func updateManeuver() {
        guard let route = currentRoute, currentStepIndex < route.steps.count else { return }
        let step = route.steps[currentStepIndex]
        nextManeuverInstruction = step.instructions
        // Initial speech for maneuver
        if !step.instructions.isEmpty {
            speak(step.instructions)
        }
    }
    
    private func clearRoute() {
        currentRoute = nil
        alternativeRoutes = []
        nextManeuverInstruction = ""
        nextManeuverDistance = 0
        eta = nil
        remainingDistance = 0
        isRerouting = false
    }
    
    public func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        speechSynthesizer.speak(utterance)
    }
    
    // Polyline math helper
    private func distance(from coord: CLLocationCoordinate2D, to polyline: MKPolyline) -> CLLocationDistance {
        // Simplified fallback point distance
        return CLLocation(latitude: coord.latitude, longitude: coord.longitude).distance(from: CLLocation(latitude: polyline.coordinate.latitude, longitude: polyline.coordinate.longitude))
    }
}
