// CarPlayNavigationManager.swift
// Manages full turn-by-turn navigation within CarPlay.
// Handles search, route calculation, guidance, and rerouting.

import Foundation
import CarPlay
import MapKit
import Combine
import AVFoundation

@MainActor
public class CarPlayNavigationManager: NSObject, NavigationActionDelegate {
    
    private let viewModel: DriveViewModel
    private let mapTemplate: CPMapTemplate
    private var navigationSession: CPNavigationSession?
    private var currentTrip: CPTrip?
    private var currentManeuver: CPManeuver?
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var isMuted: Bool = false
    
    private var currentSteps: [MKRoute.Step] = []
    private var currentStepIndex: Int = 0
    private var locationCancellable: AnyCancellable?
    
    public init(viewModel: DriveViewModel, mapTemplate: CPMapTemplate) {
        self.viewModel = viewModel
        self.mapTemplate = mapTemplate
        super.init()
        self.viewModel.navigationDelegate = self
    }
    
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
    }
    
    public func searchDestination(query: String, completion: @escaping ([MKMapItem]) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let coordinate = viewModel.locationManager.latestLocation?.coordinate ?? CLLocationCoordinate2D()
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            completion(Array(response?.mapItems.prefix(5) ?? []))
        }
    }
    
    public func startNavigation(to destination: MKMapItem) {
        Task {
            do {
                let route = try await calculateRoute(to: destination)
                self.startNavigation(route: route, destination: destination)
            } catch {
                print("Failed to calculate route: \(error)")
            }
        }
    }
    
    public func searchDestinationTrigger(_ query: String) async -> [MKMapItem] {
        return await searchDestination(query: query, near: viewModel.locationManager.latestLocation?.coordinate ?? CLLocationCoordinate2D())
    }
    
    public func startNavigationTrigger(to destination: MKMapItem, route: MKRoute?) async {
        if let providedRoute = route {
            startNavigation(route: providedRoute, destination: destination)
        } else {
            do {
                let route = try await calculateRoute(to: destination)
                startNavigation(route: route, destination: destination)
            } catch {
                print("Failed to calculate route: \(error)")
            }
        }
    }
    
    public func endNavigationTrigger() async {
        endNavigation()
    }
    
    // MARK: - Search
    public func searchDestination(query: String, near coordinate: CLLocationCoordinate2D) async -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        // 50km radius
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        request.region = region
        
        do {
            let search = MKLocalSearch(request: request)
            let response = try await search.start()
            return Array(response.mapItems.prefix(5))
        } catch {
            print("Search error: \(error)")
            return []
        }
    }
    
    // MARK: - Route Calculation
    public func calculateRoute(to destination: MKMapItem) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        
        let avoidHighways = UserDefaults.standard.bool(forKey: "avoidHighways")
        if avoidHighways {
            request.highwayPreference = .avoid
        }
        
        let directions = MKDirections(request: request)
        let response = try await directions.calculate()
        
        guard let fastest = response.routes.first else {
            throw NSError(domain: "Navigation", code: 404, userInfo: [NSLocalizedDescriptionKey: "No routes found"])
        }
        
        return fastest
    }
    
    // MARK: - Navigation Control
    public func startNavigation(route: MKRoute, destination: MKMapItem) {
        viewModel.isNavigating = true
        viewModel.currentRoute = route
        viewModel.destination = destination
        
        let estimatedTime = route.expectedTravelTime
        viewModel.eta = Date().addingTimeInterval(estimatedTime)
        
        let routeChoice = CPRouteChoice(
            summaryVariants: ["Fastest Route"],
            additionalInformationVariants: [],
            selectionSummaryVariants: ["Fastest"]
        )
        let trip = CPTrip(origin: MKMapItem.forCurrentLocation(), destination: destination, routeChoices: [routeChoice])
        self.currentTrip = trip
        
        navigationSession = mapTemplate.startNavigationSession(for: trip)
        
        currentSteps = route.steps
        
        // Skip initial steps with 0 distance (usually just the starting point)
        currentStepIndex = 0
        while currentStepIndex < currentSteps.count && currentSteps[currentStepIndex].distance <= 0 {
            currentStepIndex += 1
        }
        
        // If we skipped everything, reset to 0
        if currentStepIndex >= currentSteps.count {
            currentStepIndex = 0
        }
        
        monitorProgress()
        announce("Starting route to \(destination.name ?? "destination").")
        advanceToNextStep()
    }
    
    public func endNavigation() {
        navigationSession?.finishTrip()
        navigationSession = nil
        currentTrip = nil
        currentManeuver = nil
        locationCancellable?.cancel()
        
        viewModel.isNavigating = false
        viewModel.currentRoute = nil
        viewModel.destination = nil
        viewModel.nextManeuverInstruction = ""
        viewModel.distanceToNextTurn = 0
        viewModel.eta = nil
        
        announce("You have arrived at your destination.")
    }
    
    private func monitorProgress() {
        locationCancellable = viewModel.locationManager.$latestLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.evaluateNavigationProgress(at: location)
            }
    }
    
    private func evaluateNavigationProgress(at location: CLLocation) {
        guard let currentRoute = viewModel.currentRoute, let session = navigationSession else { return }
        
        // 1. Check distance to next turn (step)
        if currentStepIndex < currentSteps.count {
            let nextStep = currentSteps[currentStepIndex]
            let stepStart = CLLocation(latitude: nextStep.polyline.coordinate.latitude,
                                       longitude: nextStep.polyline.coordinate.longitude)
            
            let distance = location.distance(from: stepStart)
            viewModel.distanceToNextTurn = distance
            
            // Advance step if within 50 meters
            if distance < 50.0 {
                currentStepIndex += 1
                advanceToNextStep()
            }
        } else {
            // Reached destination
            if let dest = viewModel.destination?.placemark.location {
                if location.distance(from: dest) < 50.0 {
                    endNavigation()
                    return
                }
            }
        }
        
        // Update CarPlay HUD Estimates
        let totalDistance = Measurement(value: currentRoute.distance - currentRoute.distance(to: currentStepIndex), unit: UnitLength.meters)
        let timeRemaining = currentRoute.expectedTravelTime * (totalDistance.value / currentRoute.distance)
        let travelEstimates = CPTravelEstimates(distanceRemaining: totalDistance, timeRemaining: timeRemaining)
        
        if let maneuver = currentManeuver {
            session.updateEstimates(travelEstimates, for: maneuver)
        }
    }
    
    // Helper to sum distances up to index bounds safely
    private func advanceToNextStep() {
        guard currentStepIndex < currentSteps.count else { return }
        let maneuver = currentSteps[currentStepIndex]
        
        viewModel.nextManeuverInstruction = maneuver.instructions
        viewModel.nextManeuverImageName = symbolName(for: maneuver)
        
        let cpManeuver = CPManeuver()
        cpManeuver.instructionVariants = [maneuver.instructions]
        
        // Premium Icons for CarPlay
        if let icon = UIImage(systemName: symbolName(for: maneuver)) {
            cpManeuver.symbolImage = icon
        }
        
        let distanceMeasure = Measurement(value: maneuver.distance, unit: UnitLength.meters)
        cpManeuver.initialTravelEstimates = CPTravelEstimates(distanceRemaining: distanceMeasure, timeRemaining: 0) // Approximation
        
        self.currentManeuver = cpManeuver
        navigationSession?.upcomingManeuvers = [cpManeuver]
        
        if maneuver.distance > 0 {
            announce(maneuver.instructions)
        }
    }
    
    private func symbolName(for step: MKRoute.Step) -> String {
        // Basic mapping of instructions to SF Symbols
        let inst = step.instructions.lowercased()
        if inst.contains("left") { return "arrow.turn.up.left" }
        if inst.contains("right") { return "arrow.turn.up.right" }
        if inst.contains("exit") { return "arrow.up.right.circle" }
        if inst.contains("roundabout") { return "arrow.counterclockwise" }
        if inst.contains("destination") { return "mappin.and.ellipse" }
        return "arrow.up"
    }
    
    private func announce(_ message: String) {
        // Obey user voice nav setting via AppStorage if necessary, for now respect mute button:
        if isMuted || UserDefaults.standard.bool(forKey: "voiceNavEnabled") == false { return }
        
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.interruptSpokenAudioAndMixWithOthers, .duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set audio session: \(error)")
        }
        
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        speechSynthesizer.speak(utterance)
    }
}

fileprivate extension MKRoute {
    func distance(to stepIndex: Int) -> CLLocationDistance {
        var dist: CLLocationDistance = 0
        for i in 0..<stepIndex {
            if i < steps.count {
                dist += steps[i].distance
            }
        }
        return dist
    }
}
