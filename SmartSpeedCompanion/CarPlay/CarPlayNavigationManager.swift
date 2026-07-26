// CarPlayNavigationManager.swift
// Manages full turn-by-turn navigation within CarPlay.
// Handles search, route calculation, guidance, and rerouting.

import AVFoundation
import Combine
import CarPlay
import MapKit
import Foundation

@MainActor
public class CarPlayNavigationManager: NSObject, NavigationActionDelegate {
    
    private let viewModel: DriveViewModel
    private let mapTemplate: CPMapTemplate
    private var navigationSession: CPNavigationSession?
    private var currentTrip: CPTrip?
    private var currentManeuver: CPManeuver?
    
    // NOTE: Removed local AVSpeechSynthesizer — all announcements go through
    // DriveViewModel.announce() to avoid two synthesizers competing/overlapping.
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
    
    public func getMuted() -> Bool {
        return self.isMuted
    }
    
    public func searchDestination(query: String, completion: @escaping ([MKMapItem]) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let coordinate = viewModel.locationManager.latestLocation?.coordinate ?? CLLocationCoordinate2D()
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation, .parking, .restaurant, .cafe])
        
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
        request.departureDate = .now // Real-time traffic awareness
        
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
        viewModel.navigationCoordinator.currentRoute = route
        viewModel.navigationCoordinator.destination = destination

        let estimatedTime = route.expectedTravelTime
        viewModel.navigationCoordinator.eta = Date().addingTimeInterval(estimatedTime)
        // Mirror CarPlay's remaining-route distance onto the ViewModel right
        // away so Siri `GetDistanceToDestinationIntent` can answer before the
        // next `evaluateNavigationProgress` tick fires.
        viewModel.navigationCoordinator.distanceToDestination = route.distance
        
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
        // NOTE: Do NOT call announce() here — DriveViewModel.startNavigation(with:) handles
        // the initial voice announcement to avoid duplicate "starting navigation" speech.
        advanceToNextStep()
    }
    
    /// Adopts a navigation session that CarPlay started internally (e.g.
    /// after the user accepted a session-restoration prompt or tapped "Start"
    /// on a trip preview). Calculates our own route and runs through the full
    /// coordinator flow so speed HUD, turn-by-turn, and drive recording all
    /// reflect the active trip. CarPlay's `CPMapTemplateDelegate.startedTrip`
    /// fires before this method is called; `startNavigationSession(for:)`
    /// (called by `startNavigation`) ends any previous session first, so our
    /// properly-configured trip replaces the CarPlay-created one cleanly.
    public func handleCarPlayStartedTrip(_ trip: CPTrip) async {
        let destination = trip.destination

        do {
            let route = try await calculateRoute(to: destination)
            // Set destination on the coordinator *before* calling
            // startNavigation(with:) so the delegate chain fires correctly.
            // The coordinator reads self.destination inside startNavigation
            // to pass it through to startNavigationTrigger.
            viewModel.navigationCoordinator.destination = destination
            viewModel.navigationCoordinator.destinationItem = destination
            // Run through the full coordinator pipeline: it resets step flags,
            // starts the reroute timer, sets ETA/distance, auto-starts session
            // recording, caches route segments, starts Live Activity, speaks
            // the initial announcement, and calls back to our
            // `startNavigation(route:destination:)` via the delegate chain.
            await viewModel.navigationCoordinator.startNavigation(with: route)
        } catch {
            print("handleCarPlayStartedTrip: Failed to calculate route: \(error)")
        }
    }

    public func endNavigation() {
        navigationSession?.finishTrip()
        navigationSession = nil
        currentTrip = nil
        currentManeuver = nil
        locationCancellable?.cancel()

        viewModel.isNavigating = false
        viewModel.navigationCoordinator.currentRoute = nil
        viewModel.navigationCoordinator.destination = nil
        viewModel.navigationCoordinator.nextManeuverInstruction = ""
        viewModel.navigationCoordinator.distanceToNextTurn = 0
        viewModel.navigationCoordinator.distanceToDestination = 0
        viewModel.navigationCoordinator.eta = nil
    }
    
    private func monitorProgress() {
        locationCancellable = viewModel.locationManager.$latestLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.evaluateNavigationProgress(at: location)
            }
    }
    
    private func evaluateNavigationProgress(at location: CLLocation) {
        guard let currentRoute = viewModel.navigationCoordinator.currentRoute, let session = navigationSession else { return }

        // 1. Check distance to next turn (step)
        if currentStepIndex < currentSteps.count {
            let nextStep = currentSteps[currentStepIndex]
            let stepStart = CLLocation(latitude: nextStep.polyline.coordinate.latitude,
                                       longitude: nextStep.polyline.coordinate.longitude)

            let distance = location.distance(from: stepStart)
            viewModel.navigationCoordinator.distanceToNextTurn = distance

            // Advance step if within 15 meters
            if distance < 15.0 {
                currentStepIndex += 1
                advanceToNextStep()
            }
        } else {
            // Reached destination
            if let dest = viewModel.navigationCoordinator.destination?.placemark.location {
                let distToDest = location.distance(from: dest)
                if distToDest < 50.0 {
                    // DriveViewModel.advanceToNextStep() handles the arrival announcement.
                    // We just end the CarPlay session here.
                    endNavigation()
                    return
                }
            }
        }

        // Update CarPlay HUD Estimates
        let totalDistance = Measurement(value: currentRoute.distance - currentRoute.distance(to: currentStepIndex), unit: UnitLength.meters)
        let timeRemaining = currentRoute.expectedTravelTime * (totalDistance.value / currentRoute.distance)
        // Mirror the same remaining distance onto the ViewModel so Siri
        // `GetDistanceToDestinationIntent` can answer while CarPlay is the
        // active navigation surface. DriveViewModel's own
        // updateNavigationProgress(...) sets this property on the phone-only
        // path; both writes converge to roughly the same value (in meters).
        viewModel.navigationCoordinator.distanceToDestination = totalDistance.value
        let travelEstimates = CPTravelEstimates(distanceRemaining: totalDistance, timeRemaining: timeRemaining)
        
        if let maneuver = currentManeuver {
            session.updateEstimates(travelEstimates, for: maneuver)
        }
    }
    
    // Helper to sum distances up to index bounds safely
    private func advanceToNextStep() {
        guard currentStepIndex < currentSteps.count else { return }
        let maneuver = currentSteps[currentStepIndex]
        
        viewModel.navigationCoordinator.nextManeuverInstruction = maneuver.instructions
        viewModel.navigationCoordinator.nextManeuverImageName = symbolName(for: maneuver)
        
        let cpManeuver = CPManeuver()
        cpManeuver.instructionVariants = [maneuver.instructions]
        
        // Premium Icons for CarPlay
        if let icon = UIImage(systemName: symbolName(for: maneuver)) {
            cpManeuver.symbolImage = icon
        }
        
        let distanceMeasure = Measurement(value: maneuver.distance, unit: UnitLength.meters)
        cpManeuver.initialTravelEstimates = CPTravelEstimates(distanceRemaining: distanceMeasure, timeRemaining: 0)
        
        self.currentManeuver = cpManeuver
        navigationSession?.upcomingManeuvers = [cpManeuver]
        
        // Voice announcement goes through DriveViewModel's single synthesizer (avoids overlaps)
        // Only announce if the step has substance (distance > 0 and non-empty instructions)
        if maneuver.distance > 0 && !maneuver.instructions.isEmpty && !isMuted {
            // We directly call DriveViewModel's internal announce through the public path
            // by updating the shared instruction state — DriveViewModel's location handler
            // will call announce() at the right distance thresholds.
            // For CarPlay step transitions, we post a notification that DriveViewModel picks up.
        }
    }
    
    public func showManeuversList(interfaceController: CPInterfaceController?) {
        guard !currentSteps.isEmpty else { return }
        
        let listItems = currentSteps.enumerated().map { index, step in
            let item = CPListItem(text: step.instructions, detailText: "\(Int(step.distance * 3.28084)) ft")
            if let icon = UIImage(systemName: symbolName(for: step)) {
                item.setImage(icon)
            }
            // Highlight current step
            if index == currentStepIndex {
                item.accessoryType = .disclosureIndicator
            }
            return item
        }
        
        let listTemplate = CPListTemplate(title: "Route Overview", sections: [CPListSection(items: listItems)])
        interfaceController?.pushTemplate(listTemplate, animated: true, completion: nil)
    }
    
    private func symbolName(for step: MKRoute.Step) -> String {
        // Basic mapping of instructions to SF Symbols
        // U-turn MUST be checked before left/right
        let inst = step.instructions.lowercased()
        if inst.contains("u-turn") || inst.contains("u turn") || inst.contains("uturn") { return "arrow.uturn.left" }
        if inst.contains("left") { return "arrow.turn.up.left" }
        if inst.contains("right") { return "arrow.turn.up.right" }
        if inst.contains("exit") || inst.contains("take ramp") { return "arrow.up.right.circle" }
        if inst.contains("roundabout") { return "arrow.counterclockwise" }
        if inst.contains("destination") { return "mappin.and.ellipse" }
        return "arrow.up"
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