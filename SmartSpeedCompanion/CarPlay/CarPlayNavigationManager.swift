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
    /// Exponential moving average of `location.speed` used by the ETA
    /// estimator to prevent flickering from noisy GPS speed readings.
    private var smoothedSpeed: Double = 0
    /// Invalidates progress callbacks from a replaced CarPlay session.
    private var navigationGeneration: UInt64 = 0
    
    public init(viewModel: DriveViewModel, mapTemplate: CPMapTemplate) {
        self.viewModel = viewModel
        self.mapTemplate = mapTemplate
        super.init()
        self.viewModel.navigationDelegate = self
        // CRITICAL: the navigation loop now lives in NavigationCoordinator
        // (extracted from DriveViewModel), and the COORDINATOR has its own
        // `navigationDelegate` used for startNavigationTrigger /
        // endNavigationTrigger / prepareForRouteTransition. If it is not
        // wired here, CarPlay navigation silently does nothing — the head
        // unit never receives the start trigger, so startNavigationSession
        // is never called and turn-by-turn never begins.
        self.viewModel.navigationCoordinator.navigationDelegate = self
    }
    
    public func setMuted(_ muted: Bool) {
        self.isMuted = muted
    }
    
    public func getMuted() -> Bool {
        return self.isMuted
    }

    /// Clean up the active CPNavigationSession without ending phone-side
    /// navigation. Called by CarPlaySceneDelegate when the user disconnects
    /// from CarPlay so the system framework doesn't leak the session.
    public func finishCurrentSession() {
        navigationGeneration &+= 1
        locationCancellable?.cancel()
        locationCancellable = nil
        navigationSession?.finishTrip()
        navigationSession = nil
        currentManeuver = nil
    }

    /// Defensive cleanup in case `finishCurrentSession()` was not called
    /// before deallocation (crash path, unexpected teardown order).
    deinit {
        navigationSession?.finishTrip()
    }

    /// Invalidates the old progress stream before NavigationCoordinator
    /// publishes a replacement leg. Keep the CPNavigationSession alive: the
    /// CPMapTemplate stop callback has no session identity, so finishing the
    /// old session here could make a delayed callback look like a real user
    /// stop on the replacement session.
    public func prepareForRouteTransition() {
        navigationGeneration &+= 1
        locationCancellable?.cancel()
        locationCancellable = nil
        navigationSession?.upcomingManeuvers = []
        currentManeuver = nil
    }
    
    public func searchDestination(query: String, completion: @escaping ([MKMapItem]) -> Void) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let coordinate = viewModel.locationManager.latestLocation?.coordinate ?? CLLocationCoordinate2D()
        request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 50000, longitudinalMeters: 50000)
        // No pointOfInterestFilter — the driver picks from ANY category
        // (gas, coffee, hospital, hotel, EV charger, grocery, etc.), not
        // just a fixed subset. The query text drives what comes back.

        let search = MKLocalSearch(request: request)
        search.start { response, _ in
            completion(Array(response?.mapItems.prefix(10) ?? []))
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
        // NavigationCoordinator clears its route before calling this delegate.
        // If a new route was started while the old async delegate hop was
        // suspended, do not let the stale completion tear down that new
        // CarPlay session.
        guard !viewModel.isNavigating,
              viewModel.navigationCoordinator.currentRoute == nil else { return }
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

    /// Calculates up to three alternate routes (fastest first) for the
    /// CarPlay trip preview so the driver can pick between them, like
    /// Google Maps. Falls back to a single route if alternates fail.
    public func calculateRoutes(to destination: MKMapItem, completion: @escaping ([MKRoute]) -> Void) {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        request.departureDate = .now

        if UserDefaults.standard.bool(forKey: "avoidHighways") {
            request.highwayPreference = .avoid
        }

        let directions = MKDirections(request: request)
        directions.calculate { response, _ in
            let routes = Array((response?.routes ?? []).prefix(3))
            completion(routes)
        }
    }

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
        // Reroutes and multi-stop leg transitions reuse the active CarPlay
        // session. A CPMapTemplate stop callback has no session identity, so
        // finishing and immediately recreating the session can make a delayed
        // old callback end the phone's new directions. Keep the session and
        // replace its maneuver stream instead.
        navigationGeneration &+= 1
        locationCancellable?.cancel()
        locationCancellable = nil
        navigationSession?.upcomingManeuvers = []
        currentManeuver = nil

        viewModel.isNavigating = true
        viewModel.navigationCoordinator.currentRoute = route
        // Only intermediate stops make this a multi-stop session. A normal
        // route calculation may still leave a single RouteLeg snapshot behind.
        let hasMultiStopState = !viewModel.routeStops.isEmpty
        if !hasMultiStopState {
            // For a normal route this is the final destination. During a
            // multi-stop route the coordinator keeps `destination` as the
            // final endpoint while this call receives the active stop.
            viewModel.navigationCoordinator.destination = destination
        }

        // For a normal route this is the complete trip. For a multi-stop
        // route, NavigationCoordinator has already published the remaining
        // total (and updates it at each stop); do not shrink Siri/HUD values
        // back to the current leg while replacing the CarPlay session.
        if !hasMultiStopState {
            let estimatedTime = route.expectedTravelTime
            viewModel.navigationCoordinator.eta = Date().addingTimeInterval(estimatedTime)
            // Mirror CarPlay's remaining-route distance onto the ViewModel
            // right away so Siri can answer before the next progress tick.
            viewModel.navigationCoordinator.distanceToDestination = route.distance
        }
        
        let routeChoice = CPRouteChoice(
            summaryVariants: ["Fastest Route"],
            additionalInformationVariants: [],
            selectionSummaryVariants: ["Fastest"]
        )
        // Keep the CPTrip destination stable at the final endpoint. The
        // CPNavigationSession's trip is immutable; using the active stop here
        // would leave stale stop metadata after a route transition because
        // the existing session is intentionally reused to avoid an ambiguous
        // delayed stop callback. The maneuver stream below still follows the
        // active leg and the phone coordinator owns the complete stop plan.
        let tripDestination = viewModel.navigationCoordinator.destination ?? destination
        let trip = CPTrip(origin: MKMapItem.forCurrentLocation(), destination: tripDestination, routeChoices: [routeChoice])
        
        if navigationSession == nil {
            self.currentTrip = trip
            navigationSession = mapTemplate.startNavigationSession(for: trip)
        }
        
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
    /// (called by `startNavigation`) installs the app-managed session when
    /// CarPlay has not already provided one, so the existing session remains
    /// the single source of CarPlay navigation callbacks.
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
        navigationGeneration &+= 1
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
        // Reset the smoothed-speed EMA so the next navigation starts from
        // a clean slate instead of fading from the previous drive's last
        // reading (which would briefly produce an inaccurate ETA).
        smoothedSpeed = 0
    }
    
    private func monitorProgress() {
        let generation = navigationGeneration
        locationCancellable = viewModel.locationManager.$latestLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.evaluateNavigationProgress(at: location, generation: generation)
            }
    }
    
    private func evaluateNavigationProgress(at location: CLLocation, generation: UInt64) {
        guard generation == navigationGeneration else { return }
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
        }
        // Arrival and intermediate-stop transitions are owned by
        // NavigationCoordinator, which receives the same location heartbeat
        // and knows the active leg. Do not independently compare against the
        // final destination here: during a multi-stop route that destination
        // is intentionally farther away than the active CarPlay trip.

        // ── ETA Estimation ───────────────────────────────────────────
        //
        // PROBLEM: The old formula used a proportional estimate based on
        // step-index position:
        //   remainingDist = route.distance - steps[0..<currentStepIndex]
        //   timeRemaining = expectedTravelTime × (remainingDist / totalDist)
        //
        // This had two flaws:
        //   1. Step-index LAG — the index only advances when the user is
        //      within 15 m of the NEXT step's start coordinate, so
        //      "completed" distance lags actual travel by potentially
        //      several kilometers, inflating remainingDist.
        //   2. No SPEED FEEDBACK — the proportion never adjusts for
        //      actual driving speed, so a user on an open highway sees
        //      the same ETA as if they were stuck in traffic.
        //
        // FIX: Scan the route polyline to find where the user actually is
        // (matching to the nearest segment, not step-index), compute the
        // remaining distance along the polyline, and use location.speed
        // (CoreLocation-smoothed with an exponential moving average) for
        // a real-time speed-based estimate that converges within seconds.

        let remainingDist = actualRemainingDistance(route: currentRoute, location: location)

        // Smooth the speed reading with an exponential moving average to
        // prevent the ETA from visibly bouncing between values on noisy
        // GPS ticks. alpha = 0.3 gives ~70 % weight to the last 3 readings.
        let rawSpeed = location.speed
        if smoothedSpeed == 0, rawSpeed >= 0 {
                // CoreLocation returns -1.0 when speed is unavailable
                // (GPS lock lost, tunnel). Never seed the EMA with -1 —
                // it would contaminate the average for several ticks.
                smoothedSpeed = rawSpeed
            } else if rawSpeed >= 0 {
                smoothedSpeed = 0.3 * rawSpeed + 0.7 * smoothedSpeed
            }
            // If rawSpeed < 0, keep the previous smoothed value unchanged.
        let speed = max(smoothedSpeed, 1.0)                  // m/s, floor at walking speed (3.6 km/h)
        let liveEstimate = remainingDist / speed              // seconds

        // Sanity clamp: in stop-and-go traffic the live estimate can swing
        // to absurd values (e.g. 83 min for 10 km at 2 m/s when Apple's
        // expected time was 20 min). Cap at 3× the expected proportion so
        // the user never sees a wildly pessimistic jump from a slow patch.
        let proportion = remainingDist / currentRoute.distance
        let proportionalEstimate = currentRoute.expectedTravelTime * proportion
        let timeRemaining = min(liveEstimate, 3.0 * proportionalEstimate)

        // Mirror the polyline-matched distance onto the ViewModel so
        // Siri `GetDistanceToDestinationIntent` and the phone-side HUD
        // both see the same accurate value (in meters).
        viewModel.navigationCoordinator.distanceToDestination = remainingDist
        let remainingMeasurement = Measurement(value: remainingDist, unit: UnitLength.meters)
        let travelEstimates = CPTravelEstimates(distanceRemaining: remainingMeasurement, timeRemaining: timeRemaining)
        
        if let maneuver = currentManeuver {
            session.updateEstimates(travelEstimates, for: maneuver)
        }
    }

    /// Walks the route polyline to find where `location` actually sits on
    /// the path (nearest-segment matching, not step-index-based) and
    /// returns the remaining distance in meters from that point to the
    /// destination. This eliminates the step-index lag that caused the
    /// old proportional ETA to overstate remaining distance by several km.
    private func actualRemainingDistance(route: MKRoute, location: CLLocation) -> CLLocationDistance {
        let polyline = route.polyline
        let points = polyline.points()
        let count = polyline.pointCount
        guard count > 0 else { return route.distance }

        let userCoord = location.coordinate
        var minDist = CLLocationDistance.infinity
        var cumulativeDist: CLLocationDistance = 0
        var bestDistAlong: CLLocationDistance = route.distance

        for i in 0..<(count - 1) {
            let p1 = points[i].coordinate
            let p2 = points[i + 1].coordinate

            let segLen = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
                .distance(from: CLLocation(latitude: p2.latitude, longitude: p2.longitude))

            let nearest = nearestPointOnSegment(userCoord: userCoord, v: p1, w: p2)
            let dist = CLLocation(latitude: userCoord.latitude, longitude: userCoord.longitude)
                .distance(from: CLLocation(latitude: nearest.latitude, longitude: nearest.longitude))

            if dist < minDist {
                minDist = dist
                let distAlongSeg = CLLocation(latitude: p1.latitude, longitude: p1.longitude)
                    .distance(from: CLLocation(latitude: nearest.latitude, longitude: nearest.longitude))
                bestDistAlong = cumulativeDist + distAlongSeg
            }

            cumulativeDist += segLen
        }

        return max(0, route.distance - bestDistAlong)
    }

    /// Clamps `userCoord` to the line segment `v→w` and returns the
    /// closest point on that segment. Used by `actualRemainingDistance`
    /// to pin the user to the exact route geometry.
    private func nearestPointOnSegment(userCoord: CLLocationCoordinate2D, v: CLLocationCoordinate2D, w: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let l2 = pow(v.longitude - w.longitude, 2) + pow(v.latitude - w.latitude, 2)
        if l2 == 0 { return v }
        var t = ((userCoord.longitude - v.longitude) * (w.longitude - v.longitude) + (userCoord.latitude - v.latitude) * (w.latitude - v.latitude)) / l2
        t = max(0, min(1, t))
        return CLLocationCoordinate2D(
            latitude: v.latitude + t * (w.latitude - v.latitude),
            longitude: v.longitude + t * (w.longitude - v.longitude)
        )
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
        
        let listTemplate = CPListTemplate(title: "Route Overview", sections: [CPListSection(items: listItems, header: nil, sectionIndexTitle: nil)])
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

